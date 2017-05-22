# Load the Rails application.
require_relative 'application'
require "extensions/string_utils"

# Initialize the Rails application.
Rails.application.initialize!
ActionMailer::Base.smtp_settings = {
  address: "smtp.gmail.com",
  port: "587",
  authentication: :plain,
  user_name: ENV["GMAIL_USERNAME"],
  password: ENV["GMAIL_PASSWORD"],
  domain: "mail.google.com",
  enable_starttls_auto: true
}
