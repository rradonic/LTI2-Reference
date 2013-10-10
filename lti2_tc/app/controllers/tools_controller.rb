
include OAuth::OAuthProxy

class ToolsController < ApplicationController
  include Lti2Commons::Utils
  
  def create 
    rack_parameters = OAuthRequest.collect_rack_parameters request
    key = rack_parameters[:oauth_consumer_key]
    @deployment_request = DeploymentRequest.where(:reg_key => key).first

    message_type = "registration"
    secret = @deployment_request.reg_password

    (tool_proxy, status, error_msg) = process_tool_proxy(request, secret)
    if error_msg.present?
      (render :status => status, :errors => [error_msg]) and return
    end

    # generate guid for tool_proxy
    tool_proxy_guid = UUID.generate
    tool_proxy.root['tool_proxy_guid'] = tool_proxy_guid
    tool_proxy.substitute_text_in_all_nodes '{', '}', {'tool_proxy_guid' => tool_proxy_guid}       
    tool_consumer_registry = Rails.application.config.tool_consumer_registry
   
    product_name = tool_proxy.first_at('tool_profile.product_instance.product_info.product_name.default_value')

    @tool = Tool.new
    @tool.is_enabled = false
    
    @tool.tool_proxy = JSON.pretty_generate tool_proxy.root
    @tool.product_name = product_name
    @tool.description = tool_proxy.first_at('tool_profile.product_instance.product_info.description.default_value')
    @tool.key = tool_proxy_guid
    @tool.secret = tool_proxy.first_at('security_contract.shared_secret')

    # TEMPORARY: enable tool
    @tool.is_enabled = true
    
    @tool.save
    
    resource_nodes = tool_proxy.first_at('tool_profile.resource_handler')
    for resource_node in resource_nodes
      # create resource-relative jsonpath
      resource_json_obj = JsonWrapper.new resource_node
      resource = Resource.new
      resource.tool = @tool
      resource.resource_type = resource_json_obj.first_at('resource_type')
      resource.name = resource_json_obj.first_at('name.default_value')
      resource.description = resource_json_obj.first_at('description.default_value')
      resource.save
      
      # TEMPORARY: auto-create one link for SMPL101 (#2)
      link = Link.new
      link.course_id = 2  # SMPL101
      link.resource = resource
      link.resource_link_label = resource.name
      link_parameter_str = "{"
      if ["Book", "BookSelection", "InteractiveResource"].include? resource.name
        link_parameter_str += "\"vbid\":\"L-999-74180\""
      end
      if resource.name == "BookSelection"
        link_parameter_str += ",\"book_location\":\"outline\/3\""
      end
      link_parameter_str += "}"
      link.link_parameters = link_parameter_str
      
      # and a grade_item for resource iResource only
      if resource.name == "InteractiveResource"
        grade_item = GradeItem.new
        grade_item.course_id = link.course_id
        grade_item.label = "IRTestGrade"
        grade_item.save
        
        link.grade_item_id = grade_item.id
      end
      
      link.is_enabled = true
      link.save
    end

    tc_profile_url = tool_proxy.first_at('tool_consumer_profile')
    tc_profile_guid = tc_profile_url.split('/').last if tc_profile_url =~ /\//

    @deployment_request.delete

    tool_proxy_guid = tool_proxy.first_at('tool_proxy_guid')
    tool_proxy_id = "#{tool_consumer_registry.tc_deployment_url}/tools/#{tool_proxy_guid}"
    tool_proxy.root['@id'] = tool_proxy_id
    @tool.tool_proxy = JSON.pretty_generate tool_proxy.root

    capture_and_excise_settings(tool_proxy.root, @tool)

    @tool.save

    tool_proxy_response = {
      "@context" => "http://www.imsglobal.org/imspurl/lti/v2/ctx/ToolProxyId",
      "@type" => "ToolProxy",
      "@id" => tool_proxy_id,
      "tool_proxy_guid" => tool_proxy_guid
    }
    
    render :json => tool_proxy_response, :location => tool_proxy_id, :content_type => "application/vnd.ims.lti.v2.ToolProxy.id+json", :status => 201
  end

  def show
    id_parm = params[:id]
    match = /^id=(\d+)/.match(id_parm)
    if match.present?
      id = match[1]
      @tool = Tool.find_by_id(id)
    else
      @tool = Tool.where(:key => id_parm).first
    end
    (render :text => "Unauthorized", :status => 401 unless @tool.present?) and return
    secret = @tool.secret
    #oauth_validation_using_secret secret

    tool_proxy_str = @tool.tool_proxy
    tool_proxy = JSON.load(tool_proxy_str)

    # merge in Tool Settings for ToolProxy level
    tool_settings = ToolSetting.where(:scopeable_id => @tool.id)
    tool_settings_custom = {}
    tool_settings.each do |tool_setting|
      tool_settings_custom[tool_setting.name] = tool_setting.value
    end
    if tool_settings_custom.length > 0
      tool_settings_custom['@id'] = ""
      tool_proxy[:custom] = tool_settings_custom

    end

    tool_proxy_pretty_str = JSON.pretty_generate(tool_proxy)
    render :text => "<pre>#{tool_proxy_pretty_str}</pre>"
  end

  def update 
    rack_parameters = OAuthRequest.collect_rack_parameters request
    key = rack_parameters[:oauth_consumer_key]

    message_type = "reregistration"
    @tool = Tool.where(:key => key).first
    secret = @tool.secret

    oauth_validation_using_secret secret
    
    body_str = request.body.read
    json_str = CGI::unescape body_str
    tool_proxy = JsonWrapper.new(json_str)
    
    product_name = tool_proxy.first_at('tool_profile.product_instance.product_info.product_name.default_value')

    @tool.tool_proxy = JSON.pretty_generate tool_proxy.root
    @tool.product_name = product_name
    @tool.description = tool_proxy.first_at('tool_profile.product_instance.product_info.description.default_value')
    @tool.key = tool_proxy.first_at('tool_proxy_guid')
    @tool.secret = tool_proxy.first_at('security_contract.shared_secret')

    tool_proxy_guid = tool_proxy.first_at('tool_proxy_guid')
    tool_consumer_registry = Rails.application.config.tool_consumer_registry
    tool_proxy_id = "#{tool_consumer_registry.tc_deployment_url}/tools/#{tool_proxy_guid}"
    tool_proxy.root['@id'] = tool_proxy_id

    @tool.tool_proxy = JSON.pretty_generate tool_proxy.root
    # TEMPORARY: enable tool
    @tool.is_enabled = true

    capture_and_excise_settings(tool_proxy.root, @tool)

    @tool.save
    
    # 202 - Available; cf. LTI2 IG section 8.1
    render :nothing => true, :status => 202   
  end

  private

  # for this reference impl: tool proxy settings system-of-record is db not TP itself
  def capture_and_excise_settings(tool_proxy, tool)
    settings = tool_proxy['custom']
    if settings.present?
      ToolSetting.where(:scopeable_type => 'Tool', :tool_id => tool.id).delete_all

      settings.each_pair do |k,v|
        ts = ToolSetting.create(:scopeable_type => 'Tool', :tool_id => tool.id, :scopeable_id => tool.id,
                                :name => k, :value => v)
        ts.save
      end

      tool_proxy.delete('custom')

    end
  end

  def check_for_validitiy(tool_proxy)
    if tool_proxy.first_at('security_contract.shared_secret').blank?
      return 'Missing shared_secret'
    end


  end

  def process_tool_proxy(request, secret)
    begin
      oauth_validation_using_secret secret
    rescue
      return [nil, 401, 'Invalid signature']
    end

    body_str = request.body.read
    json_str = CGI::unescape body_str

    begin
      tool_proxy = JsonWrapper.new(json_str)
    rescue
      return [nil, 400, 'JSON validation failure']
    end

    error_msg = check_for_validity(tool_proxy)
    if error_msg.present?
      (render :status => 400, :errors => [error_msg]) and return
      return [nil, 400, error_msg]
    end

    [tool_proxy, nil, nil]
  end
end