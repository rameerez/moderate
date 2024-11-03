# 👮‍♂️ `moderate` - Moderate and block bad words from your Rails app

`moderate` is a Ruby gem that moderates user-generated text content by adding a simple validation to block bad words in any text field.

Simply add this to your model:

```ruby
validates :text_field, moderate: true
```

That's it! You're done. `moderate` will work seamlessly with your existing validations and error messages.

> [!WARNING]
> This gem is under development. It currently only supports a limited set of English profanity words. Word matching is very basic now, and it may be prone to false positives, and false negatives. I use it for very simple things like preventing new submissions if they contain bad words, but the gem can be improved for more complex use cases and sophisticated matching and content moderation. Please consider contributing if you have good ideas for additional features.

# Why

Any text field where users can input text may be a place where bad words can be used. This gem blocks records from being created if they contain bad words, profanity, naughty / obscene words, etc.

It's good for Rails applications where you need to maintain a clean and respectful environment in comments, posts, or any other user input.

# How

`moderate` currently downloads a list of ~1k English profanity words from the [google-profanity-words](https://github.com/coffee-and-fun/google-profanity-words) repository and caches it in your Rails app's tmp directory.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'moderate'
```

And then execute:

```bash
bundle install
```

Then, just add the `moderate` validation to any model with a text field:

```ruby
validates :text_field, moderate: true
```

`moderate` will raise an error if a bad word is found in the text field, preventing the record from being saved.

It works seamlessly with your existing validations and error messages.

## Configuration

You can configure the `moderate` gem behavior by adding a `config/initializers/moderate.rb` file:
```ruby
Moderate.configure do |config|
  # Custom error message when bad words are found
  config.error_message = "contains inappropriate language"

  # Add your own words to the blacklist
  config.additional_words = ["badword1", "badword2"]

  # Exclude words from the default list (false positives)
  config.excluded_words = ["good"]
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/moderate. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
