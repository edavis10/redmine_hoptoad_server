require 'nokogiri'

class NoticesController < ApplicationController

  skip_before_filter :check_if_login_required
  before_filter :find_or_create_custom_fields

  before_filter :check_notifier_version, :only => :create

  unloadable

  TRACE_FILTERS = [
    /^On\sline\s#\d+\sof/,
    /^\d+:/
  ]

  def create
    redmine_params = YAML.load(@xml.at_css('api-key').content)

    if (Setting.mail_handler_api_enabled? && Setting.mail_handler_api_key == redmine_params[:api_key]) ||
        project_specific_key?(redmine_params[:project], redmine_params[:api_key])

      # redmine objects
      project = Project.find_by_identifier(redmine_params[:project])
      tracker = project.trackers.find_by_name(redmine_params[:tracker])
      author  = User.anonymous

      # error class and message
      error_class   = @xml.at_xpath('/notice/error/class').content
      error_message = @xml.at_xpath('/notice/error/message').content
      backtrace     = @xml.xpath('/notice/error/backtrace/line')

      # shorten long messages
      error_message = "#{error_message[0...120]}..." if error_message.length > 255

      request            = @xml.at_xpath('/notice/request')
      server_environment = @xml.at_xpath('/notice/server-environment')
      session            = @xml.at_xpath('/notice/session')
      project_root       = @xml.at_xpath('/notice/server-environment/project-root').content + '/'

      # build filtered backtrace
      project_trace_filters = (project.custom_value_for(@trace_filter_field).value rescue '').split(/[,\s\n\r]+/)

      if backtrace.size > 0
        line = backtrace.first
        first_error = "#{line['file']}:#{line['number']}"

        repo_root = project.custom_value_for(@repository_root_field).value.gsub(/\/$/,'') rescue nil
        repo_file, repo_line = first_error.gsub('[RAILS_ROOT]','').gsub(/^\//,'').split(':')
      end

      filtered_backtrace = []

      backtrace.each do |line|
        # make the first non-hoptoad line in the stack-trace the first_error
        if line !=~ /hoptoad_notifier/
          first_error ||= line
        end

        unless (TRACE_FILTERS+project_trace_filters).map {|filter| line.to_s.scan(filter)}.flatten.compact.uniq.any?
          filtered_backtrace << "#{line['file']}:#{line['number']}:in `#{line['method']}'\n"
        end
      end

      filter_backtrace = nil unless filtered_backtrace.size > 0

      subject =
        if backtrace
          # build subject by removing method name and '[RAILS_ROOT]'
          "#{error_class} in #{first_error.gsub('[RAILS_ROOT]','').gsub(project_root, '')}"
        else
          # No backtrace, construct a simple subject
          "[#{error_class}] #{error_message.split("\n").first}"
        end[0,255] # make sure it fits in a varchar

      description =
        if backtrace
          # build description including a link to source repository
          "Redmine Notifier reported an Error related to source: #{repo_root}/#{repo_file}#L#{repo_line}"
        else
          "Redmine Notifier reported an Error"
        end

        issue = Issue.find_by_subject_and_project_id_and_tracker_id_and_author_id(subject, project.id, tracker.id, author.id)

        if issue.nil?
          issue = Issue.new
          issue.subject = subject
          issue.project = project
          issue.tracker = tracker
          issue.author = author
        end

      if issue.new_record?
        # set standard redmine issue fields
        issue.category = IssueCategory.find_by_name(redmine_params[:category]) unless redmine_params[:category].blank?
        issue.assigned_to = User.find_by_login(redmine_params[:assigned_to]) unless redmine_params[:assigned_to].blank?
        issue.priority_id = redmine_params[:priority] unless redmine_params[:priority].blank?
        issue.description = description

        # make sure that custom fields are associated to this project and tracker
        project.issue_custom_fields << @error_class_field unless project.issue_custom_fields.include?(@error_class_field)
        tracker.custom_fields << @error_class_field unless tracker.custom_fields.include?(@error_class_field)
        project.issue_custom_fields << @occurences_field unless project.issue_custom_fields.include?(@occurences_field)
        tracker.custom_fields << @occurences_field unless tracker.custom_fields.include?(@occurences_field)

        # set custom field error class
        issue.custom_values.build(:custom_field => @error_class_field, :value => error_class)
      end

      issue.save!

      # increment occurences custom field
      value = issue.custom_value_for(@occurences_field) || issue.custom_values.build(:custom_field => @occurences_field, :value => 0)
      value.value = (value.value.to_i + 1).to_s
      logger.error value.value
      value.save!

      # update journal
      journal =
        if backtrace
          issue.init_journal(
            author, # XXX - use the defined Redmine formatter, do not assume everyone uses textile!
            "h4. Error message\n\n<pre>#{error_message}</pre>\n\n" +
            "h4. Filtered backtrace\n\n<pre>#{filtered_backtrace}</pre>\n\n" +
            "h4. Full backtrace\n\n<pre>#{backtrace}</pre>\n\n" +
            "h4. Request\n\n<pre>#{request.to_xml}</pre>\n\n" +
            "h4. Session\n\n<pre>#{session.to_yaml}</pre>\n\n" +
            "h4. Environment\n\n<pre>#{server_environment.to_xml}</pre>\n\n" +
            "h4. Full XML\n\n<pre>#{@xml.to_xml}</pre>\n\n"
          )
        elsif issue.description != description # If a user sends a double feedback, save the text into a new comment
          issue.init_journal(author, description)
        end

      # reopen issue
      if issue.status.blank? or issue.status.is_closed?
        issue.status = IssueStatus.find(:first, :conditions => {:is_default => true}, :order => 'position ASC')
      end

      issue.save!

      if issue.new_record?
        Mailer.deliver_issue_add(issue) if Setting.notified_events.include?('issue_added')
      elsif journal
        Mailer.deliver_issue_edit(journal) if Setting.notified_events.include?('issue_updated')
      end

      render :status => 200, :text => "Received bug report. Created/updated issue #{issue.id}."
    else
      logger.info 'Unauthorized Hoptoad API request.'
      render :status => 403, :text => 'You provided a wrong or no Redmine API key.'
    end
  end

  def index
    notice = YAML.load(request.raw_post)['notice']
    redmine_params = YAML.load(notice['api_key'])

    if Setting.mail_handler_api_key == redmine_params[:api_key]

      # redmine objects
      project = Project.find_by_identifier(redmine_params[:project])
      tracker = project.trackers.find_by_name(redmine_params[:tracker])
      author  = User.anonymous

      # error class and message
      error_class   = notice['error_class']
      error_message = notice['error_message']
      backtrace     = notice['back'].blank? ? notice['backtrace'] : notice['back']

      # shorten long messages
      error_message = "#{error_message[0...120]}..." if error_message.length > 255

      request            = notice['request']
      server_environment = notice['server-environment']
      session            = notice['session']

      # build filtered backtrace
      backtrace = nil if backtrace.blank?

      if backtrace
        project_trace_filters = (project.custom_value_for(@trace_filter_field).value rescue '').split(/[,\s\n\r]+/)

        filtered_backtrace =
          backtrace.reject do |line|
            (TRACE_FILTERS+project_trace_filters).map {|filter| line.scan(filter)}.flatten.compact.uniq.any?
          end

        repo_root = project.custom_value_for(@repository_root_field).value.gsub(/\/$/,'')
        repo_file, repo_line = filtered_backtrace.first.split(':in').first.gsub('[RAILS_ROOT]','').gsub(/^\//,'').split(':')
      end

      subject =
        if backtrace
          # build subject by removing method name and '[RAILS_ROOT]'
          "#{error_class} in #{filtered_backtrace.first.split(':in').first.gsub('[RAILS_ROOT]','')}"
        else
          # No backtrace, construct a simple subject
          "[#{error_class}] #{error_message.split("\n").first}"
        end[0,255] # make sure it fits in a varchar

      description =
        if backtrace
          # build description including a link to source repository
          "Redmine Notifier reported an Error related to source:#{repo_root}/#{repo_file}#L#{repo_line}"
        else
          # The whole error message
          error_message
        end

      issue = Issue.find_or_initialize_by_subject_and_project_id_and_tracker_id_and_author_id(
        subject,
        project.id,
        tracker.id,
        author.id
      )

      if issue.new_record?
        # set standard redmine issue fields
        issue.category = IssueCategory.find_by_name(redmine_params[:category]) unless redmine_params[:category].blank?
        issue.assigned_to = User.find_by_login(redmine_params[:assigned_to]) unless redmine_params[:assigned_to].blank?
        issue.priority_id = redmine_params[:priority] unless redmine_params[:priority].blank?
        issue.description = description

        # make sure that custom fields are associated to this project and tracker
        project.issue_custom_fields << @error_class_field unless project.issue_custom_fields.include?(@error_class_field)
        tracker.custom_fields << @error_class_field unless tracker.custom_fields.include?(@error_class_field)
        project.issue_custom_fields << @occurences_field unless project.issue_custom_fields.include?(@occurences_field)
        tracker.custom_fields << @occurences_field unless tracker.custom_fields.include?(@occurences_field)

        # set custom field error class
        issue.custom_values.build(:custom_field => @error_class_field, :value => error_class)
      end

      issue.save!

      # increment occurences custom field
      value = issue.custom_value_for(@occurences_field) || issue.custom_values.build(:custom_field => @occurences_field, :value => 0)
      value.value = (value.value.to_i + 1).to_s
      logger.error value.value
      value.save!

      # update journal
      journal =
        if backtrace
          issue.init_journal(
            author, # XXX - use the defined Redmine formatter, do not assume everyone uses textile!
            "h4. Error message\n\n<pre>#{error_message}</pre>\n\n" +
            "h4. Filtered backtrace\n\n<pre>#{filtered_backtrace.to_yaml}</pre>\n\n" +
            "h4. Full backtrace\n\n<pre>#{backtrace.to_yaml}</pre>\n\n" +
            "h4. Request\n\n<pre>#{request.to_yaml}</pre>\n\n" +
            "h4. Session\n\n<pre>#{session.to_yaml}</pre>\n\n" +
            "h4. Environment\n\n<pre>#{server_environment.to_yaml}</pre>"
          )
        elsif issue.description != description # If a user sends a double feedback, save the text into a new comment
          issue.init_journal(author, description)
        end

      # reopen issue
      if issue.status.blank? or issue.status.is_closed?
        issue.status = IssueStatus.find(:first, :conditions => {:is_default => true}, :order => 'position ASC')
      end

      issue.save!

      if issue.new_record?
        Mailer.deliver_issue_add(issue) if Setting.notified_events.include?('issue_added')
      elsif journal
        Mailer.deliver_issue_edit(journal) if Setting.notified_events.include?('issue_updated')
      end

      render :status => 200, :text => "Received bug report. Created/updated issue #{issue.id}."
    else
      logger.info 'Unauthorized Hoptoad API request.'
      render :status => 403, :text => 'You provided a wrong or no Redmine API key.'
    end
  end

  protected

  def find_or_create_custom_fields
    @error_class_field = IssueCustomField.find_or_initialize_by_name('Error class')
    if @error_class_field.new_record?
      @error_class_field.attributes = {:field_format => 'string', :searchable => true, :is_filter => true}
      @error_class_field.save(false)
    end

    @occurences_field = IssueCustomField.find_or_initialize_by_name('# Occurences')
    if @occurences_field.new_record?
      @occurences_field.attributes = {:field_format => 'int', :default_value => '0', :is_filter => true}
      @occurences_field.save(false)
    end

    @trace_filter_field = ProjectCustomField.find_or_initialize_by_name('Backtrace filter')
    if @trace_filter_field.new_record?
      @trace_filter_field.attributes = {:field_format => 'text'}
      @trace_filter_field.save(false)
    end

    @repository_root_field = ProjectCustomField.find_or_initialize_by_name('Repository root')
    if @repository_root_field.new_record?
      @repository_root_field.attributes = {:field_format => 'string'}
      @repository_root_field.save(false)
    end
  end

  def check_notifier_version
    if request.raw_post =~ /^\<\?xml/
      @xml = Nokogiri::XML(request.raw_post)
      return @xml.at_css('notice')['version'][0].chr == '2'
    end

    return false
  end

  private

  def project_specific_key?(project_identifier, api_key)
    return false if project_identifier.blank? || api_key.blank?

    project = Project.find_by_identifier(project_identifier)
    if project
      if configured_custom_field_id = Setting.plugin_redmine_hoptoad_server["project_key_custom_field_id"]
        custom_field = ProjectCustomField.find(configured_custom_field_id)

        project_value = project.custom_value_for(custom_field)
        return project_value && project_value.value && project_value.value == api_key
      end
    end
  end
  
end
