class Deployer
  attr_accessor :organization
  attr_accessor :auth_token
  attr_reader   :errors
  
  require 'rest-client'
  require 'xml'
  
  module Exceptions
    class AuthenticationError < StandardError; end
    class NoSaltError < StandardError; end
  end
  
  def initialize(org, pub_token)
    @organization = org
    @auth_token = pub_token
    @errors = []
  end
  
  def auth_token
    return @auth_token unless @auth_token.nil?

    token = login()
    raise Exceptions::AuthenticationError.new("Can't login to deployer server for user: #{@organization.name}" ) unless token
    @auth_token = token
  end
  
  def request(method, url, params={}, is_no_auth = nil)
    default_methods = ['get', 'put', 'post', 'delete', 'options', 'head']
    raise ArgumentError.new("Unknown request method: #{method}") unless default_methods.include?(method)
    dataType = 'xml'
    url = "api/#{url}" unless url.include?("/api/")
    url = "#{url}.#{dataType}"
    params.merge!(:auth_token => auth_token) unless is_no_auth
    params = { :params => params } if ["get", "delete"].include?(method.to_s)
    begin
      response = RestClient.send(method, "#{self.class.config['url']}/#{url}", params)
    rescue RuntimeError => e
      raise "Error in connection to deploy server: #{method.upcase}, Returned: #{e}" 
    end
    data = nil
    if response.code == 200
      case dataType
      when 'json'
        data = JSON.parse(response)
      when 'xml'
        data = Hash.from_xml response
      end
    end
    data
  end
  
  def login(_login = nil, _password = nil)
    return false if @organization.deployLogin.nil? || @organization.deployPassword.nil?
    e = EncryptDecrypt.new(@organization.id)
    dec_password = e.decrypt(@organization.deployPassword)
    
    login     = _login    || @organization.deployLogin
    password  = _password || dec_password
    response = request('get', 'sessions/get', {
        :login => login,
        :password => password
    }, "no_auth");
    return false unless response.is_a?(Hash)
    @auth_token = response['hash']['auth_token']
    response['hash']['auth_token']
  end
  
  def add_target_recipe_link(targetId, recipeId, options={})
    response = request("post", "org_deploy_target_pub_recipe", {
        :deploy_target_id => targetId,
        :recipe_id        => recipeId,
        :name             => options[:name],
        :comments         => options[:comments]
    })
    return response.try(:[], "org_deploy_target_pub_recipe")
  end
  
  def update_target_recipe_link(target_recipe_id, params={})
    request("put", "org_deploy_target_pub_recipe/#{target_recipe_id}", params);
  end
  
  def delete_target_recipe_link(recipe_to_deploy_id)
    request("delete", "org_deploy_target_pub_recipe/#{recipe_to_deploy_id}")
  end
  
  def add_deploy_target(name, project_name, description = '', type = 'All')
    response = request("post", "org_deploy_target", {
      :project_name => project_name,
      :name         => name,
      :description  => description,
      :os_type      => type
    })
    response
  end
  
  def is_target_available(name, project_name)
    targets = deploy_targets(project_name)
    return true unless targets && targets[:items]
  end
  
  def deploy_targets(project_name, filter_target_id=nil, filter_recipe_id=nil)
    items = get_list('org_deploy_target', :project_name => project_name)
    return [] unless items && items[:items]

    data = items[:items]
    response = []
    data.each do |target|
      next if filter_target_id && filter_target_id != target["id"]
      recipes = []
      target["org_deploy_target_pub_recipes"].each do |target_recipe|
        next if filter_recipe_id && filter_recipe_id != target_recipe[:'pub-recipe-id']
        target["pub_recipes"].each do |recipe|
          recipe["target_recipe_id"] = target_recipe[:id]
          recipe['target_recipe_name'] = target_recipe[:name]
          recipe['target_recipe_comments'] = target_recipe[:comments]
        end
        recipes << target_recipe
      end
      target['os_type'] = "" if target['os_type'] == "All" || target['os_type'].nil?
      hash = {
          :name         => target['name'],
          :id           => target['id'],
          :type         => target['os_type'],
          :description  => target['description'],
          :recipes      => recipes
      }
      response << hash
    end
    response || []
  end
  
  def all_deploy_targets_count
    response = request("get", "org_deploy_target/org_total_targets")
    return {:total_targets => 0, :total_recipes => 0} unless response 
    response["hash"]["total_targets"].to_i
    {:total_targets => response["hash"]["total_targets"].to_i, :total_recipes => response["hash"].try('[]',"total_recipes").try(:to_i)}
  end
  
  def all_target_recipes_count(targets)
      recipes = 0
      targets.each do |target|
        recipes += target[:recipes].count
      end
      recipes
  end
  
  def delete_deploy_target(target_id, project_name)
    data = request("delete", "org_deploy_target/#{target_id}", {:project_name => project_name})
    data
  end
  
  def deploy_target_options(target_id, project_name, type)

    unless type.blank?
      if ["ssh", "gae", "aws", "for"].include?(type.downcase)
        @type = type
      else
        type = type.downcase if type == "None"
        @type = Service::Deploy.ref_to_category(type) 
        raise ArgumentError.new("Incorrect target settings type: #{type}") if @type.nil? 
      end
    else
      @type = type
    end
    
    data = {
        :targetId => target_id,
        :name => "#{@type}_option",
        :project_name => project_name
    }
    
    response = request("get", "org_deploy_target/#{target_id}", data)
    return nil unless response || response["hash"]

    resp_hash = HashWithIndifferentAccess.new
    response["hash"].each do |key, val|
      parsed_key = key
      if parsed_key == "ssh_host"
        val = val.try(:split, ",") || [""]
      end
      resp_hash[key.to_sym] = val
    end
    return resp_hash
  end
  
  def update_deploy_target_options(type, project_name=nil, description=nil, target_id=0, options = {})
    @type = type if ["ssh", "gae", "aws", "for"].include?(type.downcase)
    @type ||= Service::Deploy.ref_to_category(type) 
    raise ArgumentError.new("Incorrect target settings type: #{type}") if @type.nil?
    return nil if options.blank?
    data = options
    data[:name] = "#{@type}_option"
    data[:project_name] = project_name
    data[:description] = description
    # Special case for SSH and Joyent
    if data[:ssh_host].is_a?(Array)
      limit = @organization.limits.deployDestinationsLimit + 1
      if limit != -1 && data[:ssh_host].count > limit
        raise "Can save only #{@organization.limits.deployDestinationsLimit} hosts."
      end
      if data[:ssh_host].count == 1
        data[:ssh_host] = data[:ssh_host][0] 
      elsif data[:ssh_host].count > 1
        data[:ssh_host] = data[:ssh_host].join(",")
      end
    end
    return request("put", "org_deploy_target/#{target_id}", data)
  end
  
  def add_organization
    name      = @organization.name
    email     = @organization.owner.email
    password  = DudeTools.randomly_unique_string(:length => 10)
    
    e = EncryptDecrypt.new(@organization.id)
    @organization.deployPassword = e.encrypt(password)
    
    data = request("post", "users", {:name=>name,
       :password => password,
       :email    => email
    }, "no_auth")
    return false unless (data || data[:user] || data[:user]['organization-id'])
    
    @organization.deployLogin = data["user"]["login"]
    return false unless @organization.save
    data
  end
  
  def organization
      begin
        data = request("get", "organizations", {:name => @organization.name})
        return nil if data["nil_classes"]
        return false unless data["organizations"] || data["organizations"][0]
        data["organizations"][0]
      rescue => e
        @errors << e
        return nil
      end
  end
  
  def delete_organization(org_id)
    request("delete", "organizations/#{org_id}")
  end
  
  def add_project(name, description="")
    data = request("post", "projects", {
      :name         => name,
      :description  => description
    })
    data
  end
  
  def project(name)
  	data = request("get","projects", { :name => name });
  	return nil if data["nil_classes"]
  	return nil unless data["projects"] || data["projects"][0]
    data["projects"][0]
  end
  
  def delete_project(project_id)
    request("delete", "projects/#{project_id}")
  end
  
  # get a signle recipe by id
  def recipe(recipe_id)
    data = get_list("pub_recipes", :id => recipe_id)
    if data && data[:items]
      data[:items] = [data[:items]] unless data[:items].is_a?(Array)
    end
    data[:items][0] || nil
  end
  
  # get all recipes
  def recipes(recipe_id=nil, type = "Team Edition Deploy", os="")
    data = get_list("pub_recipes", :id => recipe_id, :os => os, :type => type)
    if data && data[:items]
      data[:items] = [data[:items]] unless data[:items].is_a?(Array)
    end
    data[:items] || []
  end
  
  def all_target_recipes(user, limit=10)
    recipes = []
    Project.all_for(user).each do |project|
      if project.service_installed?(:deploy)
        deploy_targets(project.shortName).each do |target|
          target[:recipes].each do |recipe|
            recipes << recipe.merge(:service => project.services.where(:serviceType => :deploy).first, :target => target)
          end
        end
      end
    end
    recipes.sort_by!{|r| r["updated_at"]}.reverse[0...limit]
  end
  
  def get_questions(recipe_id=nil, target_id=nil, target_recipe_id=nil)
    return nil unless recipe_id || target_recipe_id
    items = get_list("question_wizard", 
                     :target_recipe_id => target_recipe_id,
                     :recipe_id        => recipe_id,
                     :target_id        => target_id
                    )
    return nil unless items[:items] 
    data = items[:items]
  end
  
  def save_answers(recipe_id=nil, target_id=nil, target_recipe_id=nil, answers={})
    return nil unless target_recipe_id || (recipe_id && target_id)
    answers ||= {}
    raise "Answers parameter must be a hash ({key => val})" unless answers.is_a?(Hash) || answers.is_a(HashWithIndifferentAccess)
    questions = get_questions(recipe_id, target_id, target_recipe_id)
    return nil unless questions
    data={}
    questions.each do |question|
      answer = answers[question["id"].to_s]
      key = "answer_"
      key += "pub_question_" if question["pub_question_id"]
      key += "config_question_" if question["config_question_id"]
      key += question["pub_question_id"] ? question["pub_question_id"].to_s : question["id"].to_s
      data[key] = answer
    end
    data.merge!({
        :recipe_id => recipe_id,
        :target_id => target_id,
        :target_recipe_id => target_recipe_id
    })
    request("post", "question_wizard", data)
  end
  
  
  def deploy_url(pub_target_id, odtpr_id, pub_recipe_id)
    "#{self.class.config['deploy']}/question_wizard/deploy?type=pub_recipe&download_type=deploy&org_deploy_target_id1=#{pub_target_id}&odtpr_id=#{odtpr_id}&pub_recipe_id=#{pub_recipe_id}&auth_token=#{self.login}"
  end
  
protected

  def self.config
    unless defined? @config
      config = YAML.load(ERB.new(File.read(File.join(Rails.root, 'config', 'deployer.yml'))).result).to_hash
      config = config[Rails.env] or raise RuntimeError.new("Missing #{Rails.env} block in config/deployer.yml")
      @config = config
    end
    @config
  end
  
  def get_list(action, params={})
    id_filter = ""
    id_filter = "/#{params[:id]}" if params[:id]
    data = request("get", "#{action}#{id_filter}", params.except(:id))
    action.gsub!('_','-')
    if data[:action]
      data = data[:action]
    elsif data["#{action}s"]
      data = data["#{action}s"]
    end
    if data.count == 1
      keys = data.map{|k,v| k }
      return {:items => data[keys[0]]}
    end
    data
  end
  
end

