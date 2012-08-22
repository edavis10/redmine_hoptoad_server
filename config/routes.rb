Rails.application.routes.draw do
  match '/notifier_api/v2/notices/' => 'notices#create'
end
