require 'xmlhash'
require 'event'
require 'opensuse/backend'

include MaintenanceHelper

class BsRequest < ActiveRecord::Base
  class InvalidStateError < APIException
    setup 'request_not_modifiable', 404
  end
  class InvalidReview < APIException
    setup 'invalid_review', 400, 'request review item is not specified via by_user, by_group or by_project'
  end
  class InvalidDate < APIException
    setup 'invalid_date', 400
  end
  class UnderEmbargo < APIException
    setup 'under_embargo', 400
  end
  class SaveError < APIException
    setup 'request_save_error'
  end

  SEARCHABLE_FIELDS = [
    'bs_requests.creator',
    'bs_requests.priority',
    'bs_request_actions.target_project',
    'bs_request_actions.source_project',
    'bs_request_actions.type'
  ]

  scope :to_accept, -> { where(state: 'new').where('accept_at < ?', DateTime.now) }
  # Scopes for collections
  scope :with_actions, -> { joins(:bs_request_actions).distinct.order(priority: :asc, id: :desc) }
  scope :in_states, ->(states) { where(state: states) }
  scope :with_types, ->(types) { where('bs_request_actions.type in (?)', types).references(:bs_request_actions) }
  scope :from_source_project, ->(source_project) { where('bs_request_actions.source_project = ?', source_project).references(:bs_request_actions) }
  scope :in_ids, ->(ids) { where(id: ids) }
  # Searching capabilities using dataTable (1.9)
  scope :do_search, lambda {|search|
    where([SEARCHABLE_FIELDS.map { |field| "#{field} like ?" }.join(' or '),
           ["%#{search}%"] * SEARCHABLE_FIELDS.length].flatten)
  }

  has_many :bs_request_actions, -> { includes([:bs_request_action_accept_info]) }, dependent: :destroy
  has_many :reviews, :dependent => :delete_all
  has_and_belongs_to_many :bs_request_action_groups, join_table: :group_request_requests
  has_many :comments, :dependent => :delete_all, inverse_of: :bs_request, class_name: 'CommentRequest'
  validates_inclusion_of :state, :in => VALID_REQUEST_STATES
  validates :creator, :presence => true
  validate :check_supersede_state
  validate :check_creator, :on => [ :create, :save! ]
  validates_length_of :comment, :maximum => 300000
  validates_length_of :description, :maximum => 300000

  after_update :send_state_change

  def save!
    new = self.created_at ? nil : 1
    sanitize! if new and not @skip_sanitize
    super
    notify if new
  end

  def set_add_revision
    @addrevision = true
  end

  def set_ignore_build_state
    @ignore_build_state = true
  end

  def skip_sanitize
    @skip_sanitize = true
  end

  def check_creator
    unless self.creator
      errors.add(:creator, 'No creator defined')
    end
    user = User.get_by_login self.creator
    unless user
      errors.add(:creator, "Invalid creator specified #{self.creator}")
    end
    unless user.is_active?
      errors.add(:creator, "Login #{user.login} is not an active user")
    end
  end

  def check_supersede_state
    if self.state == :superseded and ( not self.superseded_by.is_a?(Numeric) or not self.superseded_by > 0 )
      errors.add(:superseded_by, 'Superseded_by should be set')
    end
    if self.superseded_by and not self.state == :superseded
      errors.add(:superseded_by, 'Superseded_by should not be set')
    end
  end

  def superseding
    BsRequest.where(superseded_by: id)
  end

  def state
    read_attribute(:state).to_sym
  end

  after_rollback :reset_cache
  after_save :reset_cache

  def reset_cache
    return unless id
    Rails.cache.delete("xml_bs_request_fullhistory_#{id}")
    Rails.cache.delete("xml_bs_request_history_#{id}")
    Rails.cache.delete("xml_bs_request_#{id}")
  end

  def self.new_from_xml(xml)
    hashed = Xmlhash.parse(xml)

    raise SaveError, 'Failed parsing the request xml' unless hashed

    if hashed['id']
      theid = hashed.delete('id') { raise 'not found' }
      theid = Integer(theid)
    else
      theid = nil
    end

    if hashed['submit'] && hashed['type'] == 'submit'
      # old style, convert to new style on the fly
      hashed.delete('type')
      hashed['action'] = hashed.delete('submit')
      hashed['action']['type'] = 'submit'
    end

    request = nil

    BsRequest.transaction do
      request = BsRequest.new
      request.id = theid if theid

      actions = hashed.delete('action')
      if actions.kind_of? Hash
        actions = [actions]
      end

      request.priority = hashed.delete('priority') || 'moderate'

      state = hashed.delete('state') || Xmlhash::XMLHash.new({'name' => 'new'})
      request.state = state.delete('name') || 'new'
      request.state = :declined if request.state.to_s == 'rejected'
      request.state = :accepted if request.state.to_s == 'accept'
      request.state = request.state.to_sym

      request.comment = state.value('comment')
      state.delete('comment')

      request.commenter = state.delete('who')
      unless request.commenter
        raise 'no one logged in and no user in request' unless User.current
        request.commenter = User.current.login
      end
      # to be overwritten if we find history
      request.creator = request.commenter

      actions.each do |ac|
        a = BsRequestAction.new_from_xml_hash(ac)
        request.bs_request_actions << a
        a.bs_request = request
      end if actions

      str = state.delete('when')
      request.updated_at = Time.zone.parse(str) if str
      str = state.delete('superseded_by') || ''
      request.superseded_by = Integer(str) unless str.blank?
      raise ArgumentError, "too much information #{state.inspect}" unless state.blank?

      request.description = hashed.value('description')
      hashed.delete('description')

      str = hashed.value('accept_at')
      request.accept_at = DateTime.parse(str) if str
      hashed.delete('accept_at')
      raise SaveError, 'Auto accept time is in the past' if request.accept_at and request.accept_at < DateTime.now

      # we do not support to import history anymore on purpose
      # would be all fake, but means also history gets lost when
      # updating from OBS 2.3 or older.
      hashed.delete('history')

      reviews = hashed.delete('review')
      if reviews.kind_of? Hash
        reviews = [reviews]
      end
      reviews.each do |r|
        request.reviews << Review.new_from_xml_hash(r)
      end if reviews

      raise ArgumentError, "too much information #{hashed.inspect}" unless hashed.blank?

      request.updated_at ||= Time.now
    end
    request
  end

  def to_axml(opts = {})
    if opts[:withfullhistory]
      Rails.cache.fetch("xml_bs_request_fullhistory_#{id}") do
        render_xml({withfullhistory: 1})
      end
    elsif opts[:withhistory]
      Rails.cache.fetch("xml_bs_request_history_#{id}") do
        render_xml({withhistory: 1})
      end
    else
      Rails.cache.fetch("xml_bs_request_#{id}") do
        render_xml
      end
    end
  end

  def to_axml_id
    # FIXME: naming it axml is nonsense if it's just a string
    "<request id='#{self.id}'/>\n"
  end

  def render_xml(opts = {})
    builder = Nokogiri::XML::Builder.new
    builder.request(id: self.id) do |r|
      self.bs_request_actions.each do |action|
        action.render_xml(r)
      end
      attributes = {name: self.state, who: self.commenter, when: self.updated_at.strftime('%Y-%m-%dT%H:%M:%S')}
      attributes[:superseded_by] = self.superseded_by if self.superseded_by

      r.priority self.priority unless self.priority == "moderate"

      r.state(attributes) do |s|
        comment = self.comment
        comment ||= ''
        s.comment! comment
      end

      self.reviews.each do |review|
        review.render_xml(r)
      end

      if opts[:withfullhistory] or opts[:withhistory]
        attributes = {who: self.creator, when: self.created_at.strftime('%Y-%m-%dT%H:%M:%S')}
        builder.history(attributes) do
          # request description is on purpose the comment in history:
          builder.description! "Request created"
          builder.comment! self.description unless self.description.blank?
        end
      end
      if opts[:withfullhistory]
        History.find_by_request(self, {withreviews: 1}).each do |history|
          # we do ignore the review history here on purpose to stay compatible
          history.render_xml(r)
        end
      elsif opts[:withhistory]
        History.find_by_request(self).each do |history|
          # we do ignore the review history here on purpose to stay compatible
          history.render_xml(r)
        end
      end

      r.accept_at self.accept_at unless self.accept_at.nil?
      r.description self.description unless self.description.nil?
    end
    builder.to_xml :save_with => Nokogiri::XML::Node::SaveOptions::NO_DECLARATION |
                                 Nokogiri::XML::Node::SaveOptions::FORMAT
  end

  def is_reviewer? (user)
    return false if self.reviews.blank?

    self.reviews.each do |r|
      if r.by_user
        return true if user.login == r.by_user
      elsif r.by_group
        return true if user.is_in_group? r.by_group
      elsif r.by_project
        if r.by_package
          pkg = Package.find_by_project_and_name r.by_project, r.by_package
          return true if pkg and user.can_modify_package? pkg
        else
          prj = Project.find_by_name r.by_project
          return true if prj and user.can_modify_project? prj
        end
      end
    end

    false
  end

  def obsolete_reviews(opts)
    return false unless opts[:by_user] or opts[:by_group] or opts[:by_project] or opts[:by_package]
    reviews.each do |review|
      if review.by_user and review.by_user == opts[:by_user] or
          review.by_group and review.by_group == opts[:by_group] or
          review.by_project and review.by_project == opts[:by_project] or
          review.by_package and review.by_package == opts[:by_package]
        logger.debug "Obsoleting review #{review.id}"
        review.state = :obsoleted
        review.save
        history = HistoryElement::ReviewObsoleted
        history.create(review: review, comment: "reviewer got removed", user_id: User.current.id)

        # Maybe this will turn the request into an approved state?
        if self.state == :review and self.reviews.where(state: "new").none?
          self.state = :new
          self.save
          history = HistoryElement::RequestAllReviewsApproved
          history.create(request: self, comment: opts[:comment], user_id: User.current.id)
        end
      end
    end
  end

  def remove_from_group(group)
    self.bs_request_action_groups.delete(group)
    # this request could be the last one in review
    group.check_for_group_in_new

    # and now check the reviews
    if self.bs_request_action_groups.empty? and self.state == :review
      self.reviews.each do |r|
        # if the review is open, there is nothing we have to care about
        return if r.state == :new
      end
      self.comment = "removed from group #{group.bs_request.id}"
      self.state = :new
      self.save

      p={request: self, comment: "Reopened by removing from group #{group.bs_request.id}", user_id: User.current.id}
      HistoryElement::RequestReopened.create(p)
    end
  end

  def permission_check_change_review!(params)
    checker = BsRequestPermissionCheck.new(self, params)
    checker.cmd_changereviewstate_permissions(params)
  end

  def permission_check_setincident!(incident)
    checker = BsRequestPermissionCheck.new(self, {:incident => incident})
    checker.cmd_setincident_permissions
  end

  def permission_check_setpriority!
    checker = BsRequestPermissionCheck.new(self, {})
    checker.cmd_setpriority_permissions
  end

  def permission_check_addreview!
    # allow request creator to add further reviewers
    checker = BsRequestPermissionCheck.new(self, {})
    checker.cmd_addreview_permissions(self.creator == User.current.login || self.is_reviewer?(User.current))
  end

  def permission_check_change_groups!
    # adding and removing of requests is only allowed for groups
    if self.bs_request_actions.first.action_type != :group
      raise GroupRequestSpecial.new "Command is only valid for group requests"
    end
  end

  def permission_check_change_state!(opts)
    checker = BsRequestPermissionCheck.new(self, opts)
    checker.cmd_changestate_permissions(opts)

    # check target write permissions
    if opts[:newstate] == 'accepted'
      self.bs_request_actions.each do |action|
        action.check_action_permission!(true)
        action.check_for_expand_errors! !@addrevision.nil?
        self.raisepriority(action.minimum_priority)
      end
    end
  end

  def changestate_accepted(opts)
    # all maintenance_incident actions go into the same incident project
    incident_project = nil  # .where(type: 'maintenance_incident')
    self.bs_request_actions.each do |action|
      source_project = Project.find_by_name(action.source_project)
      if action.source_project && action.is_maintenance_release?
        if source_project.kind_of?(Project)
          at = AttribType.find_by_namespace_and_name!('OBS', 'EmbargoDate')
          attrib = source_project.attribs.where(attrib_type_id: at.id).first
          v = attrib.values.first if attrib
          if defined?(v) && v
            begin
              embargo = DateTime.parse(v.value)
              if v.value =~ /^\d{4}-\d\d?-\d\d?$/
                # no time specified, allow it next day
                embargo = embargo.tomorrow
              end
            rescue ArgumentError
              raise InvalidDate, "Unable to parse the date in OBS:EmbargoDate of project #{source_project.name}: #{v}"
            end
            if embargo > DateTime.now
              raise UnderEmbargo, "The project #{source_project.name} is under embargo until #{v}"
            end
          end
        end
      end

      next unless action.is_maintenance_incident?

      target_project = Project.get_by_name action.target_project
      # create a new incident if needed
      if target_project.is_maintenance?
        # create incident if it is a maintenance project
        incident_project ||= MaintenanceIncident.build_maintenance_incident(target_project, source_project.nil?, self).project
        opts[:check_for_patchinfo] = true

        unless incident_project.name.start_with?(target_project.name)
          raise MultipleMaintenanceIncidents.new 'This request handles different maintenance incidents, this is not allowed !'
        end
        action.target_project = incident_project.name
        action.save!
      end
    end

    # We have permission to change all requests inside, now execute
    self.bs_request_actions.each do |action|
      action.execute_accept(opts)
    end

    # now do per request cleanup
    self.bs_request_actions.each do |action|
      action.per_request_cleanup(opts)
    end
  end

  def changestate_revoked
    self.bs_request_actions.where(type: 'maintenance_release').each do |action|
      # unlock incident project in the soft way
      prj = Project.get_by_name(action.source_project)
      prj.unlock_by_request(self.id)
    end
  end

  def change_state(opts)
    self.with_lock do
      self.permission_check_change_state!(opts)
      changestate_revoked if opts[:newstate] == 'revoked'
      changestate_accepted(opts) if opts[:newstate] == 'accepted'

      state = opts[:newstate].to_sym
      bs_request_actions.each do |a|
        # "inform" the actions
        a.request_changes_state(state)
      end
      self.bs_request_action_groups.each do |g|
        g.remove_request(self.id)
        if opts[:superseded_by] && state == :superseded
          g.addrequest('newid' => opts[:superseded_by])
        end
      end
      self.state = state
      self.commenter = User.current.login
      self.comment = opts[:comment]
      self.superseded_by = opts[:superseded_by]

      # check for not accepted reviews on re-open
      if state == :new || state == :review
        self.reviews.each do |review|
          if review.state != :accepted
            # FIXME3.0 review history?
            review.state = :new
            review.save!
            self.state = :review
          end
        end
      end
      self.save!

      params={request: self, comment: opts[:comment], user_id: User.current.id}
      case opts[:newstate]
        when "accepted" then
          history = HistoryElement::RequestAccepted
        when "declined" then
          history = HistoryElement::RequestDeclined
        when "revoked" then
          history = HistoryElement::RequestRevoked
        when "superseded" then
          history = HistoryElement::RequestSuperseded
          params[:description_extension] = self.superseded_by.to_s
        when "review" then
          history = HistoryElement::RequestReopened
        when "new" then
          history = HistoryElement::RequestReopened
        else
          raise RuntimeError, "Unhandled state #{opts[:newstate]} for history"
      end
      history.create(params)
    end
  end

  def _assignreview_update_reviews(reviewer, opts)
    review_comment = nil
    self.reviews.reverse_each do |review|
      next if review.by_user
      next if review.by_group && review.by_group != opts[:by_group]
      next if review.by_project && review.by_project != opts[:by_project]
      next if review.by_package && review.by_package != opts[:by_package]

      # approve for this review
      if opts[:revert]
        review.state = :new
        review_comment = "revert the "
        history_class = HistoryElement::ReviewReopened
      else
        review.state = :accepted
        review_comment = ""
        history_class = HistoryElement::ReviewAccepted
      end
      review.save!

      review_comment += "review for group #{opts[:by_group]}" if opts[:by_group]
      review_comment += "review for project #{opts[:by_project]}" if opts[:by_project]
      review_comment += "review for package #{opts[:by_project]} / #{opts[:by_package]}" if opts[:by_package]
      history_class.create(review: review, comment: "review assigend to user #{reviewer.login}", user_id: User.current.id)
    end
    raise Review::NotFoundError.new unless review_comment
    review_comment
  end
  private :_assignreview_update_reviews

  def assignreview(opts = {})
    unless self.state == :review || (self.state == :new && state == :new)
      raise InvalidStateError.new 'request is not in review state'
    end
    reviewer = User.find_by_login!(opts[:reviewer])

    Review.transaction do
      review_comment = _assignreview_update_reviews(reviewer, opts)

      # check if user is a reviewer already
      user_review = self.reviews.where(by_user: reviewer.login).last
      if opts[:revert]
        raise Review::NotFoundError.new unless user_review
        raise InvalidStateError.new "review is not in new state" unless user_review.state == :new
        raise Review::NotFoundError.new "Not an assigned review" unless HistoryElement::ReviewAssigned.where(op_object_id: user_review.id).last
        user_review.destroy
      else
        if user_review
          user_review.state = :new
          user_review.save!
          HistoryElement::ReviewReopened.create(review: user_review, comment: review_comment, user: User.current)
        else
          user_review = self.reviews.create(by_user: reviewer.login, creator: User.current.login)
          user_review.state = :new
          user_review.save!
          HistoryElement::ReviewAssigned.create(review: user_review, comment: review_comment, user: User.current)
        end
      end
      self.save!
    end
  end

  def change_review_state(new_review_state, opts = {})
    self.with_lock do
      new_review_state = new_review_state.to_sym

      unless self.state == :review || (self.state == :new && new_review_state == :new)
        raise InvalidStateError.new 'request is not in review state'
      end
      check_if_valid_review!(opts)
      unless [:new, :accepted, :declined, :superseded].include? new_review_state
        raise InvalidStateError.new "review state must be new, accepted, declined or superseded, was #{new_review_state}"
      end
      # to track if the request state needs to be changed as well
      go_new_state = :review
      go_new_state = new_review_state if [:declined, :superseded].include? new_review_state
      found = false

      reviews_seen = Hash.new
      self.reviews.reverse_each do |review|
        matching = true
        matching = false if review.by_user && review.by_user != opts[:by_user]
        matching = false if review.by_group && review.by_group != opts[:by_group]
        matching = false if review.by_project && review.by_project != opts[:by_project]
        matching = false if review.by_package && review.by_package != opts[:by_package]

        rkey = "#{review.by_user}@#{review.by_group}@#{review.by_project}@#{review.by_package}"

        # This is needed for MeeGo BOSS, which adds multiple reviews b
        # FIXME3.0: think about review ordering and make reviews addressable
        if matching && !(reviews_seen.has_key?(rkey) && review.state == :accepted)
          reviews_seen[rkey] = 1
          found = true
          comment = opts[:comment] || ''
          if review.state != new_review_state || review.reviewer != User.current.login || review.reason != comment
            review.reason = comment
            review.state = new_review_state
            review.reviewer = User.current.login
            review.save!

            history = nil
            history = HistoryElement::ReviewAccepted if new_review_state == :accepted
            history = HistoryElement::ReviewDeclined if new_review_state == :declined
            history = HistoryElement::ReviewReopened if new_review_state == :new
            history.create(review: review, comment: opts[:comment], user_id: User.current.id) if history

            # last review finished:
            go_new_state = :new if go_new_state == :review && review.state == :accepted
            # take decline in any situation:
            go_new_state = review.state if go_new_state == :review && review.state != :new
          else
            # no new history entry
            go_new_state = nil
          end
        else
          # don't touch the request state if a review is still open, except the review
          # got declined or superseded or reopened.
          go_new_state = nil if review.state == :new && go_new_state != :declined && go_new_state != :superseded
        end
      end
      raise Review::NotFoundError.new unless found
      history=nil
      p={request: self, comment: opts[:comment], user_id: User.current.id}
      if new_review_state == :superseded
        self.state = :superseded
        self.superseded_by = opts[:superseded_by]
        history = HistoryElement::RequestSuperseded
        p[:description_extension] = self.superseded_by.to_s
        self.save!
        history.create(p)
      elsif go_new_state # either no open reviews anymore or going back to review
        if go_new_state == :new
          history = HistoryElement::RequestAllReviewsApproved
          # if it would go to new, we need to check if all groups agree
          self.bs_request_action_groups.each do |g|
            if g.find_review_state_of_group == :review
              go_new_state = nil
              history = nil
            end
          end
          # if all groups agreed, we can set all now to new
          if go_new_state
            self.bs_request_action_groups.each do |g|
              g.set_group_to_new
            end
          end
        elsif go_new_state == :review
          self.bs_request_action_groups.each do |g|
            g.set_group_to_review
          end
        elsif go_new_state == :declined
          history = HistoryElement::RequestDeclined
        else
          raise RuntimeError, "Unhandled state #{go_new_state} for history"
        end
        self.state = go_new_state if go_new_state

        self.commenter = User.current.login
        self.comment = opts[:comment]
        self.comment = 'All reviewers accepted request' if go_new_state == :accepted
      end
      self.save!
      history.create(p) if history

      # we want to check right now if pre-approved requests can be processed
      if go_new_state == :new and self.accept_at
        Delayed::Job.enqueue AcceptRequestsJob.new
      end
    end
  end

  def check_if_valid_review!(opts)
    if !opts[:by_user] && !opts[:by_group] && !opts[:by_project]
      raise InvalidReview.new
    end
  end

  def addreview(opts)
    self.permission_check_addreview!

    self.with_lock do
      check_if_valid_review!(opts)

      self.state = 'review'
      self.commenter = User.current.login
      self.comment = opts[:comment] if opts[:comment]

      newreview = self.reviews.create reason: opts[:comment], by_user: opts[:by_user],
                                      by_group: opts[:by_group], by_project: opts[:by_project],
                                      by_package: opts[:by_package], creator: User.current.login
      self.save!
      p={request: self, user_id: User.current.id, description_extension: newreview.id.to_s}
      p[:comment] = opts[:comment] if opts[:comment]
      HistoryElement::RequestReviewAdded.create(p)
      newreview.create_notification(self.notify_parameters)
    end
  end

  def setpriority(opts)
    self.permission_check_setpriority!

    unless [ 'low', 'moderate', 'important', 'critical' ].include? opts[:priority]
      raise SaveError, "Illegal priority '#{opts[:priority]}'"
    end

    p={request: self, user_id: User.current.id, description_extension: "#{self.priority} => #{opts[:priority]}"}
    p[:comment] = opts[:comment] if opts[:comment]

    self.priority = opts[:priority]
    self.save!
    reset_cache

    HistoryElement::RequestPriorityChange.create(p)
  end

  def raisepriority(new)
    # rails enums do not support compare and break db constraints :/
    if new == "critical"
      self.priority = new
    elsif new == "important" and [ "moderate", "low" ].include? self.priority
      self.priority = new
    elsif new == "moderate" and "low" == self.priority
      self.priority = new
    end
  end

  def setincident(incident)
    self.permission_check_setincident!(incident)

    touched = false
    # all maintenance_incident actions go into the same incident project
    p={request: self, user_id: User.current.id}
    self.bs_request_actions.where(type: 'maintenance_incident').each do |action|
      tprj = Project.get_by_name action.target_project

      # use an existing incident
      if tprj.is_maintenance?
        tprj = Project.get_by_name(action.target_project + ':' + incident.to_s)
        action.target_project = tprj.name
        action.save!
        touched = true
        p[:description_extension] = tprj.name
      end
    end

    if touched
      self.save!
      HistoryElement::RequestSetIncident.create(p)
    end
  end

  IntermediateStates = %w(new review)

  def send_state_change
    return if self.state_was.to_s == self.state.to_s
    # new->review && review->new are not worth an event - it's just spam
    return if IntermediateStates.include?(self.state.to_s) && IntermediateStates.include?(self.state_was.to_s)
    Event::RequestStatechange.create(self.notify_parameters)
  end

  ActionNotifyLimit=50

  def notify_parameters(ret = {})
    ret[:id] = self.id
    ret[:description] = self.description
    ret[:state] = self.state
    ret[:oldstate] = self.state_was if self.state_changed?
    ret[:who] = self.commenter if self.commenter.present?
    ret[:when] = self.updated_at.strftime('%Y-%m-%dT%H:%M:%S')
    ret[:comment] = self.comment
    ret[:author] = self.creator

    # Use a nested data structure to support multiple actions in one request
    ret[:actions] = []
    self.bs_request_actions[0..ActionNotifyLimit].each do |a|
      ret[:actions] << a.notify_params
    end
    ret
  end

  def self.actions_summary(payload)
    ret = []
    payload.with_indifferent_access['actions'][0..ActionNotifyLimit].each do |a|
      str = "#{a['type']} #{a['targetproject']}"
      str += "/#{a['targetpackage']}" if a['targetpackage']
      str += "/#{a['targetrepository']}" if a['targetrepository']
      ret << str
    end
    ret.join(', ')
  end

  def review_matches_user?(review, user)
    return false unless user
    if review.by_user
      return user.login == review.by_user
    end
    if review.by_group
      return user.is_in_group?(review.by_group)
    end
    if review.by_project
      p = nil
      m = 'change_project'
      if review.by_package
        p = Package.find_by_project_and_name(review.by_project, review.by_package)
        m = 'change_package'
      else
        p = Project.find_by_name(review.by_project)
      end
      return false unless p
      return user.has_local_permission?(m, p)
    end
    false
  end

  def reviews_for_user_and_others(user)
    user_reviews, other_open_reviews = [], []
    self.reviews.where(state: 'new').each do |review|
      if review_matches_user?(review, user)
        user_reviews << review.webui_infos
      else
        other_open_reviews << review.webui_infos
      end
    end
    return user_reviews, other_open_reviews
  end

  def webui_infos(opts = {})
    opts.reverse_merge!(diffs: true)
    result = Hash.new
    result['id'] = self.id

    result['description'] = self.description
    result['priority'] = self.priority
    result['state'] = self.state
    result['creator'] = User.find_by_login(self.creator)
    result['created_at'] = self.created_at
    result['accept_at'] = self.accept_at if self.accept_at
    result['superseded_by'] = self.superseded_by if self.superseded_by
    result['superseding'] = self.superseding unless self.superseding.empty?
    result['is_target_maintainer'] = self.is_target_maintainer?(User.current)

    result['my_open_reviews'], result['other_open_reviews'] = self.reviews_for_user_and_others(User.current)

    result['actions'] = self.webui_actions(opts[:diffs])
    result
  end

  def auto_accept
    # do not run for processed requests. Ignoring review on purpose since this
    # must also work when people do not react anymore
    return unless self.state == :new or self.state == :review

    self.with_lock do
      User.current ||= User.find_by_login self.creator

      begin
        change_state({:newstate => 'accepted', :comment => 'Auto accept'})
      rescue BsRequestPermissionCheck::NotExistingTarget
        change_state({:newstate => 'revoked', :comment => 'Target disappeared'})
      rescue PostRequestNoPermission
        change_state({:newstate => 'revoked', :comment => 'Permission problem'})
      rescue APIException
        change_state({:newstate => 'declined', :comment => 'Unhandled error during accept'})
      end
    end
  end

  def self.delayed_auto_accept
    BsRequest.to_accept.each do |r|
      r.delay.auto_accept
    end
  end

  # Check if 'user' is maintainer in _all_ request targets:
  def is_target_maintainer?(user = User.current)
    has_target, is_target_maintainer = false, true
    self.bs_request_actions.each do |a|
      next unless a.target_project
      if a.target_package
        tpkg = Package.find_by_project_and_name(a.target_project, a.target_package)
        if tpkg
          has_target = true
          is_target_maintainer &= user.can_modify_package?(tpkg)
          next
        end
      end
      tprj = Project.find_by_name(a.target_project)
      if tprj
        has_target = true
        is_target_maintainer &= user.can_modify_project?(tprj)
      end
    end
    has_target && is_target_maintainer
  end

  def sanitize!
    # apply default values, expand and do permission checks
    self.creator ||= User.current.login
    self.commenter ||= User.current.login
    # FIXME: Move permission checks to controller level
    unless self.creator == User.current.login or User.current.is_admin?
      raise SaveError, 'Admin permissions required to set request creator to foreign user'
    end
    unless self.commenter == User.current.login or User.current.is_admin?
      raise SaveError, 'Admin permissions required to set request commenter to foreign user'
    end

    # ensure correct initial values, no matter what has been sent to us
    self.state = :new

    # expand release and submit request targets if not specified
    expand_targets

    self.bs_request_actions.each do |action|
      # permission checks
      action.check_action_permission!
      action.check_for_expand_errors! !@addrevision.nil?
      self.raisepriority(action.minimum_priority)
    end

    # Autoapproval? Is the creator allowed to accept it?
    if self.accept_at
      self.permission_check_change_state!({:newstate => 'accepted'})
    end

    apply_default_reviewers
  end

  def set_accept_at!(time = nil)
    # Approve a request to be accepted when the reviews finished
    self.permission_check_change_state!({:newstate => 'accepted'})

    self.accept_at = time || Time.now
    self.save!
    reset_cache
  end

  def apply_default_reviewers
    #
    # Find out about defined reviewers in target
    #
    # check targets for defined default reviewers
    reviewers = []

    self.bs_request_actions.each do |action|
      reviewers += action.default_reviewers

      action.create_post_permissions_hook({
         per_package_locking: @per_package_locking
      })
    end

    # apply reviewers
    reviewers.uniq.each do |r|
      if r.class == User
        next if self.reviews.select{|a| a.by_user == r.login}.length > 0
        self.reviews.new(by_user: r.login, state: :new)
      elsif r.class == Group
        next if self.reviews.select{|a| a.by_group == r.title}.length > 0
        self.reviews.new(by_group: r.title, state: :new)
      elsif r.class == Project
        next if self.reviews.select{|a| a.by_project == r.name and a.by_package.nil? }.length > 0
        self.reviews.new(by_project: r.name, state: :new)
      elsif r.class == Package
        next if self.reviews.select{|a| a.by_project == r.project.name and a.by_package == r.name }.length > 0
        self.reviews.new(by_project: r.project.name, by_package: r.name, state: :new)
      else
        raise 'Unknown review type'
      end
    end
    self.state = :review if self.reviews.select{|a| a.state == :new}.length > 0
  end

  def notify
    notify = self.notify_parameters
    Event::RequestCreate.create notify

    self.reviews.each do |review|
      review.create_notification(notify)
    end
  end

  def webui_actions(with_diff = true)
    # TODO: Fix!
    actions = []
    self.bs_request_actions.each do |xml|
      action = {type: xml.action_type}

      if xml.source_project
        action[:sprj] = xml.source_project
        action[:spkg] = xml.source_package if xml.source_package
        action[:srev] = xml.source_rev if xml.source_rev
      end
      if xml.target_project
        action[:tprj] = xml.target_project
        action[:tpkg] = xml.target_package if xml.target_package
        action[:trepo] = xml.target_repository if xml.target_repository
      end
      if xml.target_releaseproject
        action[:releaseproject] = xml.target_releaseproject
      end

      case xml.action_type # All further stuff depends on action type...
        when :submit then
          action[:name] = "Submit #{action[:spkg]}"
          action[:sourcediff] = xml.webui_infos if with_diff
          creator = User.find_by_login(self.creator)
          target_package = Package.find_by_project_and_name(action[:tprj], action[:tpkg])
          action[:creator_is_target_maintainer] = true if creator.has_local_role?(Role.rolecache['maintainer'], target_package)

          if target_package
            linkinfo = target_package.linkinfo
            target_package.developed_packages.each do |dev_pkg|
              action[:forward] ||= []
              action[:forward] << {project: dev_pkg.project.name, package: dev_pkg.name, type: 'devel' }
            end
            if linkinfo
              lprj, lpkg = linkinfo['project'], linkinfo['package']
              link_is_already_devel = false
              if action[:forward]
                action[:forward].each do |forward|
                  if forward[:project] == lprj && forward[:package] == lpkg
                    link_is_already_devel = true
                    break
                  end
                end
              end
              unless link_is_already_devel
                action[:forward] ||= []
                action[:forward] << {project: linkinfo['project'], package: linkinfo['package'], type: 'link'}
              end
            end
          end

        when :delete then
          if action[:tpkg]
            action[:name] = "Delete #{action[:tpkg]}"
          elsif action[:trepo]
            action[:name] = "Delete #{action[:trepo]}"
          else
            action[:name] = "Delete #{action[:tprj]}"
          end

          if action[:tpkg] # API / Backend don't support whole project diff currently
            action[:sourcediff] = xml.webui_infos if with_diff
          end
        when :add_role then
          action[:name] = 'Add Role'
          action[:role] = xml.role
          action[:user] = xml.person_name
        when :change_devel then
          action[:name] = 'Change Devel'
        when :set_bugowner then
          action[:name] = 'Set Bugowner'
        when :maintenance_incident then
          action[:name] = "Incident #{action[:spkg]}"
          action[:sourcediff] = xml.webui_infos if with_diff
        when :maintenance_release then
          action[:name] = "Release #{action[:spkg]}"
          action[:sourcediff] = xml.webui_infos if with_diff
      end
      actions << action
    end
    actions
  end

  def expand_targets
    newactions = []
    oldactions = []

    self.bs_request_actions.each do |action|
      na, ppl = action.expand_targets(!@ignore_build_state.nil?)
      @per_package_locking ||= ppl
      next if na.nil?

      oldactions << action
      newactions.concat(na)
    end
    # will become an empty request
    raise MissingAction.new if newactions.empty? and oldactions.size == self.bs_request_actions.size

    oldactions.each { |a| self.bs_request_actions.destroy a }
    newactions.each { |a| self.bs_request_actions << a }
  end

  def self.collection(opts)
    roles = opts[:roles] || []
    states = opts[:states] || []
    types = opts[:types] || []
    review_states = opts[:review_states] || ['new']
    # Setup the collection based on params
    requests = with_actions
    requests = requests.in_states(states) unless states.blank?
    requests = requests.with_types(types) unless types.blank?
    unless opts[:source_project].blank?
      requests = requests.from_source_project(opts[:source_project])
    end
    unless opts[:project].blank?
      requests = extend_query_for_project(requests, roles, states, review_states, opts[:package], opts[:subprojects], opts[:project])
    end
    if opts[:user]
      requests = extend_query_for_user(opts[:user], requests, roles, review_states)
    end
    if opts[:group]
      requests = extend_query_for_group(opts[:group], requests, roles, review_states)
    end
    requests = requests.in_ids(opts[:ids]) if opts[:ids]
    requests = requests.do_search(opts[:search]) if opts[:search]
    requests
  end

  def self.list_ids(opts)
    # All types means don't pass 'type'
    if opts[:types] == 'all' || (opts[:types].respond_to?(:include?) && opts[:types].include?('all'))
      opts.delete(:types)
    end
    # Do not allow a full collection to avoid server load
    if opts[:project].blank? && opts[:user].blank? && opts[:package].blank?
      raise RuntimeError, 'This call requires at least one filter, either by user, project or package'
    end
    roles = opts[:roles] || []
    states = opts[:states] || []

    # it's wiser to split the queries
    if opts[:project] && roles.empty? && (states.empty? || states.include?('review'))
      rel = collection(opts.merge(roles: %w(reviewer)))
      ids = rel.ids
      rel = collection(opts.merge(roles: %w(target source)))
    else
      rel = collection(opts)
      ids = []
    end
    ids.concat(rel.ids)
  end

  def self.extend_query_for_group(group, requests, roles, review_states)
    inner_or = []
    group = Group.find_by_title!(group)

    # find requests where group is maintainer in target project
    requests, inner_or = extend_query_for_maintainer(group, requests, roles, inner_or)

    if roles.empty? || roles.include?('reviewer')
      requests = requests.includes(:reviews).references(:reviews)
      # requests where the user is reviewer or own requests that are in review by someone else
      or_in_and = %W(reviews.by_group=#{quote(group.title)})

      requests, inner_or = extend_query_for_involved_reviews(group, or_in_and, requests, review_states, inner_or)
    end
    if inner_or.empty?
      requests.none
    else
      requests.where(inner_or.join(' or '))
    end
  end

  def self.extend_query_for_user(user, requests, roles, review_states)
    inner_or = []
    user = User.find_by_login!(user)

    # user's own submitted requests
    if roles.empty? || roles.include?('creator')
      inner_or << "bs_requests.creator = #{quote(user.login)}"
    end
    # find requests where user is maintainer in target project
    requests, inner_or = extend_query_for_maintainer(user, requests, roles, inner_or)
    if roles.empty? || roles.include?('reviewer')
      requests = requests.includes(:reviews).references(:reviews)

      # requests where the user is reviewer or own requests that are in review by someone else
      or_in_and = %W(reviews.by_user=#{quote(user.login)})

      # include all groups of user
      usergroups = user.groups.map { |group| "'#{group.title}'" }
      or_in_and << "reviews.by_group in (#{usergroups.join(',')})" unless usergroups.blank?

      requests, inner_or = extend_query_for_involved_reviews(user, or_in_and, requests, review_states, inner_or)
    end
    if inner_or.empty?
      requests.none
    else
      requests.where(inner_or.join(' or '))
    end
  end

  def self.extend_query_for_project(requests, roles, states, review_states, package, subprojects, project)
    inner_or = []
    requests, inner_or = extend_relation('source', requests, roles, package, subprojects, project, inner_or)
    requests, inner_or = extend_relation('target', requests, roles, package, subprojects, project, inner_or)

    if (roles.empty? || roles.include?('reviewer')) &&
       (states.empty? || states.include?('review'))
      requests = requests.references(:reviews)
      review_states.each do |review_state|
        requests = requests.includes(:reviews)
        if package.blank?
          inner_or << "(reviews.state=#{quote(review_state)} and reviews.by_project=#{quote(project)})"
        else
          inner_or << "(reviews.state=#{quote(review_state)} and reviews.by_project=#{quote(project)} and reviews.by_package=#{quote(package)})"
        end
      end
    end
    if inner_or.empty?
      requests.none
    else
      requests.where(inner_or.join(' or '))
    end
  end

  def self.extend_relation(source_or_target, requests, roles, package, subprojects, project, inner_or)
    if roles.empty? || roles.include?(source_or_target)
      requests = requests.references(:bs_request_actions)
      if package.blank?
        if subprojects.blank?
          inner_or << "bs_request_actions.#{source_or_target}_project=#{quote(project)}"
        else
          inner_or << "(bs_request_actions.#{source_or_target}_project like #{quote(project + ':%')})"
        end
      else
        inner_or << "(bs_request_actions.#{source_or_target}_project=#{quote(project)} and " +
          "bs_request_actions.#{source_or_target}_package=#{quote(package)})"
      end
    end
    [requests, inner_or]
  end

  def self.extend_query_for_maintainer(obj, requests, roles, inner_or)
    if roles.empty? || roles.include?('maintainer')
      names = obj.involved_projects.pluck('name').map { |p| quote(p) }
      requests = requests.references(:bs_request_actions)
      inner_or << "bs_request_actions.target_project in (#{names.join(',')})" unless names.empty?
      ## find request where group is maintainer in target package, except we have to project already
      obj.involved_packages.each do |ip|
        inner_or << "(bs_request_actions.target_project='#{ip.project.name}' and bs_request_actions.target_package='#{ip.name}')"
      end
    end
    [requests, inner_or]
  end

  def self.extend_query_for_involved_reviews(obj, or_in_and, requests, review_states, inner_or)
    review_states.each do |review_state|
      # find requests where obj is maintainer in target project
      projects = obj.involved_projects.pluck('projects.name').map { |project| quote(project) }
      or_in_and << "reviews.by_project in (#{projects.join(',')})" unless projects.blank?

      ## find request where user is maintainer in target package, except we have to project already
      obj.involved_packages.select('name,project_id').includes(:project).each do |ip|
        or_in_and << "(reviews.by_project='#{ip.project.name}' and reviews.by_package='#{ip.name}')"
      end

      inner_or << "(reviews.state=#{quote(review_state)} and (#{or_in_and.join(' or ')}))"
    end
    [requests, inner_or]
  end

  def self.quote(str)
    connection.quote(str)
  end
end
