require 'io/console'
require 'uri'
require 'net/https'
require 'json'
require 'date'


BYTES_IN_MEGABYTE=1024*1024

class Repo
  attr_reader :name
  attr_accessor :size
  attr_accessor :human_readable_size
  attr_accessor :has
  attr_accessor :last_commit_date

  OVERSIZE_THRESHOLD=20

  def initialize(params)
    @name = params[:name]
    @size = params[:size_in_megabytes]
    @human_readable_size = params[:human_readable_size]
    @has = Hash.new
    @has[:readme]  			= params[:has_readme]
    @has[:license] 			= params[:has_license]
    @has[:authors] 			= params[:has_authors]
    @has[:contributors] = params[:has_contributors]
    @last_commit_date 	= params[:last_commit_date]
  end

  def oversized?
    @size > OVERSIZE_THRESHOLD
  end
  
  def has_all_files?
  	@has.values.all? {|e| e==true }
  end

  def old?
    if @last_commit_date
      diff_date =  Time.now - @last_commit_date
      diff_date/(24*60*60) > 120
    else
      false
    end
  end
end

class Project
  attr_reader :name
  attr_reader :repos

  def initialize(name)
    @name  = name
    @repos = []
  end

  def add_repo(repo)
    @repos << repo
  end

end

class StashRequester
  attr_reader :user
  attr_reader :pass
  attr_reader :base_path
  attr_reader :uri
  attr_reader :finished
  attr_reader :progress_message


  def initialize(user, pass, base_path)
    @user, @pass, @base_path = user, pass, base_path
    @uri = Hash.new
    @uri[:get_repos]        = "%{url}/rest/api/1.0/repos?limit=%{limit}"
    @uri[:get_file]       	= "%{url}/rest/api/1.0/projects/%{project_key}/repos/%{name}/browse/%{file}?type=true"
    @uri[:get_size]         = "%{url}/rest/reposize/latest/projects/%{project_key}/repos/%{name}"
    @uri[:get_last_commit]  = "%{url}/rest/api/1.0/projects/%{project_key}/repos/%{name}/commits?limit=1"
  end

  def make_request_to(uri, args={})
    template_args = {:url => @base_path}
    template_args = template_args.merge args
    uri = URI.parse uri % template_args
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Get.new(uri.request_uri)
    req.basic_auth(@user, @pass)
    http.use_ssl = (uri.scheme == "https")
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.request(req)
  end

  def get_info(filter)
    slugs = get_slugs.select {|s| s[:project_name][/#{filter}/]}
    puts "Retrieving info from #{slugs.size} repositories"
    slugs.each do |slug|
			puts "[#{slug[:name]}]"
      #1. get repo info (files)
      response = make_request_to @uri[:get_file], slug.merge({file: 'README.md'})
      slug[:has_readme] = JSON.parse(response.body).has_key? "type"
      response = make_request_to @uri[:get_file], slug.merge({file: 'LICENSE'})
      slug[:has_license] = JSON.parse(response.body).has_key? "type"
      response = make_request_to @uri[:get_file], slug.merge({file: 'AUTHORS'})
      slug[:has_authors] = JSON.parse(response.body).has_key? "type"
      response = make_request_to @uri[:get_file], slug.merge({file: 'CONTRIBUTORS'})
      slug[:has_contributors] = JSON.parse(response.body).has_key? "type"



      #2. get repo size (this works only if the 'reposize' plugin is installed)
      response = make_request_to @uri[:get_size], slug
      parsed_response = JSON.parse(response.body)
      slug[:size_in_megabytes]   = parsed_response['sizeRaw'].to_f / BYTES_IN_MEGABYTE
      slug[:human_readable_size] = parsed_response['size']

      #3. get last commit to know if the repo is currently being used
      response = make_request_to @uri[:get_last_commit], slug
      parsed_response = JSON.parse response.body
      if parsed_response['values']
        timestamp_in_msec = parsed_response['values'].first['authorTimestamp']
        slug[:last_commit_date] = Time.at(timestamp_in_msec/1000)
      end
    end
    slugs = slugs.group_by {|x| x[:project_name]}

    projects = []
    slugs.each do |name,repos|
      project = Project.new(name)
      repos.each do |repo|
        project.add_repo Repo.new(repo)
      end
      projects << project
    end
    projects

  end

  def get_slugs
    slugs = []
    begin
      response = make_request_to @uri[:get_repos], {limit: 1000}
      parsed_body = JSON.parse response.body
      is_last_page |= parsed_body['isLastPage']
      slugs_block = parsed_body['values'].map do |v|
        {:name => v["slug"],
         :project_name => v["project"]["name"],
         :project_key => v["project"]["key"]}
      end
      slugs += slugs_block
    end until true
    slugs
  end


end

require 'erb'

def get_template
  template_name = File.join(File.dirname(__FILE__), "template.html.erb")
  File.read(template_name)
end

def serialize(projects)
  template = ERB.new(get_template)
  File.open('output.html','w') do
    |file|
    file.write template.result(binding)
  end
end



if ARGV[0]
	stash_url = ARGV[0]
	puts
	print "Username:"
	user_name = $stdin.gets.chomp
	print "Pass:"
	pass = STDIN.noecho(&:gets).chomp
	puts

	requester = StashRequester.new user_name, pass, stash_url
	projects  = requester.get_info ARGV[1]

	serialize projects
	
end

