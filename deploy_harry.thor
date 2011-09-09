# encoding: utf-8
require "rubygems"
require "thor"
require "net/http"

module SimpleApi
  extend self
  def post(request, payload)
    config = YAML.load_file("./config.yml")
    http_r = Net::HTTP.new(config['harry_host'], config['harry_port'])
    http_r.use_ssl = false
    response = nil
    http_r.start() do |http|
      req = Net::HTTP::Post.new(request)
      req.add_field("TOKEN", config['harry_token'])
      req.body = payload
      req.set_form_data(payload)
      response = http.request(req)
    end
    return [response.code, response.body]
  end
end

class Harry < Thor
  include Thor::Actions
  desc "deploy", "setup the first user"
  def deploy
    # params[:name], params[:url], params[:bundler]
    name = "glaucus"
    url = "git://github.com/Udot/glaucus.git"
    bundler = "true"
    payload = {"name" => name, "repository" => url, "bundler" => "lah", "no_register" => 1}
    SimpleApi.post("/",payload)
  end
end
