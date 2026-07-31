Rails.application.routes.draw do
  # Mounted unconditionally so specs can verify the middleware's env gate.
  mount Rails::Hyperdrive::Engine => "/_hyperdrive"
  get "/health", to: proc { [200, {}, ["ok"]] }
end
