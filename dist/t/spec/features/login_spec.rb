require "spec_helper"
#for getting spec file
require 'tmpdir'
require "net/https"
require "uri"

RSpec.describe "Sign Up & Login" do
  it "should be able to sign up successfully and logout" do
    visit "/"
    expect(page).to have_content("Log In")
    fill_in 'login', with: 'test_user'
    fill_in 'email', with: 'test_user@openqa.com'
    fill_in 'pwd', with: 'opensuse'
    click_button('Sign Up')
    expect(page).to have_content("The account 'test_user' is now active.")
    within("div#subheader") do
      click_link('Logout')
    end
  end
end

RSpec.describe "Create Interconnect as admin and build pckg" do
  it "should be able to add Opensuse Interconnect as Admin" do
    visit "/user/login"
    fill_in 'user_login', with: 'Admin'
    fill_in 'user_password', with: 'opensuse'
    click_button('Log In »')
    visit "/configuration/interconnect"
    click_button('openSUSE')
    click_button('Save changes')
  end

  it "should be able to create home project" do
    click_link('Create Home')
    expect(page).to have_content("Create New Project")
    find('input[name="commit"]').click #Create Project
    expect(page).to have_content("Project 'home:Admin' was created successfully")
  end

  it "should be able to create a new package from OBS:Server:Unstable/build/build.spec and _service files" do
    dir = Dir.mktmpdir
    File.write("#{dir}/build.spec", Net::HTTP.get(URI.parse("https://api.opensuse.org/public/source/OBS:Server:Unstable/build/build.spec")))
    find('img[title="Create package"]').click
    expect(page).to have_content("Create New Package for home:Admin")
    fill_in 'name', with: 'obs-build'
    find('input[name="commit"]').click #Save changes
    expect(page).to have_content("Package 'obs-build' was created successfully")
    find('img[title="Add file"]').click
    expect(page).to have_content("Add File to")
    attach_file("file", "#{dir}/build.spec")
    find('input[name="commit"]').click #Save changes
    expect(page).to have_content("Source Files")
    File.write("#{dir}/_service", Net::HTTP.get(URI.parse("https://api.opensuse.org/public/source/OBS:Server:Unstable/build/_service")))
    find('img[title="Add file"]').click
    expect(page).to have_content("Add File to")
    attach_file("file", "#{dir}/_service")
    find('input[name="commit"]').click #Save changes
    expect(page).to have_content("Source Files")
  end

  it "should be able to add build targets from existing repos" do
    click_link('build targets')
    expect(page).to have_content("openSUSE distributions")
    check('repo_openSUSE_Tumbleweed')
    check('repo_openSUSE_Leap_42.1')
    find('input[id="submitrepos"]').click #Add selected repositories
    expect(page).to have_content("Successfully added repositories")
    expect(page).to have_content("openSUSE_Leap_42.1 (x86_64)")
    expect(page).to have_content("openSUSE_Tumbleweed (i586, x86_64)")
  end

  it "should be able to Overview Build Results" do
    click_link('Overview')
    expect(page).to have_content("Build Results")
  end

  it "should be able to check Build Results and see succeeded package built" do
    visit "/package/live_build_log/home:Admin/obs-build/openSUSE_Tumbleweed/i586"
    wait_for_ajax
    visit "/package/live_build_log/home:Admin/obs-build/openSUSE_Leap_42.1/x86_64"
    wait_for_ajax
    visit "/project/show/home:Admin/"
    click_link('Build Results')
    counter = 30
    while (page.has_no_link?('scheduled: 1') || page.has_no_link?('building: 1')) && counter > 0 do
      sleep(4)
      click_link('Build Results')
      puts "Refreshed Build Results @ #{Time.now}, #{counter} retries left."
      counter -= 1
    end
    page.all('a', :text =>'succeeded: 1', :count => 2, :wait => 30)
  end
end
