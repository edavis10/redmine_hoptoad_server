require 'redmine'

Redmine::Plugin.register :redmine_hoptoad_server do
  name 'Hoptoad Server'
  author 'Jan Schulz-Hofen, Marcello Barnaba, Matt McMahand, Eric Davis'
  description 'Redmine acts as an Hoptoad server with this plugin. Hoptoad is an HTTP(S) API, available at http://www.hoptoadapp.com/, to allow automatic reporting of application exceptions. This flavour of the plugin allows Redmine to receive plain-text notifications, useful if you use the Hoptoad facility for e.g. user feedbacks'
  version '0.0.3'

  settings({:partial => 'settings/hoptoad_server',
             :default => {
               'project_key_custom_field_id' => nil
             }})
end
