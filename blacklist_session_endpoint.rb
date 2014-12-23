class BlacklistSessionEndpoint

	attr_accessor :action, :controller, :url, :request_methods

	BLACKLISTED_ENDPOINTS = [
		{:action=>"tokens", :controller=>"api/v1/oauth"},
		{:action=>"tokens", :controller=>"api/v1/oauth2", :request_methods => [:post, :put]}
	]

	def initialize(opts={})
		@action				= opts[:action]
		@controller			= opts[:controller]
		@url				= "#{opts[:controller]}/#{opts[:action]}"
		@request_methods	= opts[:request_types] || [:get, :post, :put, :delete]
	end

	def self.allows?(request)
		endpoints = BlacklistSessionEndpoint.all
		endpoints.each do |endpoint|
			return false if request.request_uri.include?(endpoint.url) && endpoint.request_methods.include?(request.request_method)
		end
		true
	end

	def self.all
		endpoints = []
		BLACKLISTED_ENDPOINTS.each do |endpoint|
			endpoints << BlacklistSessionEndpoint.new(endpoint)
		end
		endpoints
	end
end