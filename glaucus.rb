# server spawner module
# using chef and knife
# env needed : chef client install with knife and the following gems :
#     net-ssh net-ssh-multi fog highline --no-rdoc --no-ri --verbose
#
require "rubygems"
require "yaml"
require "json"
require "fog"
require "net/ssh"
require "redis"

conf = YAML.load_file("conf_rackspace.yml")

module EggApi
  require 'net/http'
  require "net/https"
  extend self

  def register(register_json)
    return post("/api/server/status",register_json)
  end

  private
  def get(request)
    config = YAML.load_file("#{SRC_DIR}/config/config.yml")
    http_r = Net::HTTP.new(@config['egg_api']['host'], @config['egg_api']['port'])
    http_r.use_ssl = @config['egg_api']['ssl']
    response = nil
    begin
      http_r.start() do |http|
        req = Net::HTTP::Get.new('/api/web/' + request)
        req.add_field("USERNAME", @config['egg_api']['username'])
        req.add_field("TOKEN", @config['egg_api']['token'])
        response = http.request(req)
      end
      return [response.code, response.body]
    rescue Errno::ECONNREFUSED
      @logger.error("front server didn't answer !")
      return [503, "unavailable"]
    end
  end
  def post(request,payload)
    http_r = Net::HTTP.new(@config['egg_api']['host'], @config['egg_api']['port'])
    http_r.use_ssl = config['egg_api']['ssl']
    response = nil
    begin
      http_r.start() do |http|
        req = Net::HTTP::Post.new(request, initheader = {'Content-Type' =>'application/json'})
        req.add_field("USERNAME", @config['egg_api']['username'])
        req.add_field("TOKEN", @config['egg_api']['token'])
        req.body = payload
        req.set_form_data(payload)
        response = http.request(req)
      end
    rescue Errno::ECONNREFUSED
      return [503, "unavailable"]
    end
    return [response.code, response.body]
  end
end


class Server
  # flavor :
  #     1 = 256MB RAM, 10GB HD
  #     2 = 512MB RAM, 20GB HD
  #     3 = 1024MB RAM, 40GB HD
  #     4 = 2048MB RAM, 80GB HD
  # image : 10194286, home made squeeze chef ready image
  #
  # role is a chef role
  #
  attr_accessor :hostname, :nodename, :image, :flavor, :role, :log, :connection
  attr_accessor :redis_queue, :redis_status, :token
  # rackspace specific attributes
  attr_accessor :provider_id, :host_id, :image_name, :flavor_name, :metadata
  attr_accessor :public_ip, :private_ip, :password, :state, :progress
  attr_accessor :bootstrap_log
  
  def initialize(hostname, role, image = 10194286, flavor = 1, token)
    current_path = File.expand_path(File.dirname(__FILE__))
    config = YAML.load_file(current_path + "/config.yml")
    @hostname = hostname
    @nodename = hostname
    @image = image
    @flavor = flavor
    @role = role
    @provider_id = nil
    @token = token                    # unique identifier of server, will be written to /etc/sol_token.txt
                                      # cuddy will pick it up, sol will use it to for app deployment and key
                                      # in some of the redis dbs
    @connection = Fog::Compute.new(:provider => "Rackspace",
      :rackspace_api_key => config['rackspace_token'],
      :rackspace_username => config['rackspace_username'],
      :rackspace_auth_url => config['rackspace_auth_host'])
    @status = ""
    @ready = false
    @redis_queue = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['queue_db'])
    @redis_status = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['status_db']) 
  end

  def create
    server = connection.servers.create(
              :name => hostname,
              :image_id => image,
              :flavor_id => flavor,
              :metadata => ""
            )
    server.wait_for { ready? }
    # server ready we store up stuff about the server
    self.provider_id = server.id
    self.host_id = server.host_id
    self.image_name = server.image.name
    self.flavor_name = server.flavor.name
    self.metadata = server.metadata
    self.public_ip = server.addresses["public"][0]
    self.private_ip = server.addresses['private'][0]
    self.password = server.password
    self.state = server.state
    self.progress = server.progress
  end

  def bootstrap
    current_path = File.expand_path(File.dirname(__FILE__))
    config = YAML.load_file(current_path + "/config.yml")
    # connect using ssh to get the chef bootstrap script
    result = ""
    begin
      Net::SSH.start(public_ip, "root", :password => password) do|ssh|
        self.bootstrap_log = ssh.exec!("cd /tmp && wget #{config['sol_files_host']}/client_bootstrap.sh && bash /tmp/client_bootstrap.sh www-base")
      end
    rescue rescue Net::SSH::AuthenticationFailed
      return false
    end
    return true
  end

  def to_h
    arh = { "name" => nodename,
      "image" => image,
      "flavor" => flavor,
      "role" => role,
      "provider_id" => provider_id,
      "host_id" => host_id,
      "image_name" => image_name,
      "flavor_name" => flavor_name,
      "public_ip" => public_ip,
      "private_ip" => private_ip,
      "state" => state,
      "progess" => progess}
    return arh
  end

  def set_status(status_string)
    # key is server token content is (jsoned) hash :
    #    { "name" => string,                     # the name of the server
    #      "image" => integer,                   # the image id used to create it
    #      "flavor" => integer,                  # the flavor id used to create it
    #      "role" => string,                     # the role used to create it
    #      "provider_id" => integer,             # the provider id of the server (must store, need to do actions on the servers)
    #      "host_id" => integer,                 # host id, for provider needs (must store too)
    #      "image_name" => string,               # the image name
    #      "flavor_name" => string,              # the flavor name
    #      "public_ip" => string,                # the public ip (must store)
    #      "private_ip" => string,               # the private ip (must store)
    #      "state" => string,                    # the state on provider's side
    #      "progess" => integer,                 # the progress on provider's side (percentage)
    #      "status" => string,                   # one of  "waiting", "spawning", "created", "running", "out"
    #      "started_at" => string,               # time of start of the process
    #      "finished_at" => string,              # time of finish of the status
    # }
    old_status = JSON.parse(redis_status.get(token))
    start_time = Time.now.to_s
    finish_time = Time.now.to_s
    start_time = old_status['started_at'] if old_status != nil
    arh = self.to_h
    self.status = status_string
    arh["status"] = status_string
    arh['started_at'] = start_time
    arh['finished_at'] = finish_time
    redis_status.set(token, arh.to_json)
  end

  def run
    set_status("spawning")
    self.create
    set_status("created")
    self.bootstrap
    set_status("running")
  end
end

# input loop
redis_queue = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['queue_db'])

while true
  queue = JSON.parse(redis_queue.get("queue")) unless redis_queue.get("queue") == nil
  queue ||= Array.new
  while queue.size > 0
    # "queue" (jsoned) array with items :
    #    { "name" => string,         # hostname
    #      "role" => string,         # chef role
    #      "image" => integer,       # image id for rackspace, if nil then 10194286 (a base squeeze) is used
    #      "flavor" => integer,      # server size 1 = 256MB, 2 = 512MB, 3 = 1024MB ..., default = 1 (if nil)
    #      "token" => string         # unique token to identify server, will be picked up by cuddy in /etc/sol_token.txt
    # }
    serv = queue.pop
    # don't do any
    server = Server.new(serv['name'], serv['role'], serv['image'], serv['flavor'], serv['token'])
    fork {
      server.run
    }
    redis_queue.set("queue", queue.to_json)
  end  
  sleep(10)
end

