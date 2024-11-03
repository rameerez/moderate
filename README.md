# 🗑️ `moderate` - Moderate and block bad words from your Rails app

`moderate` is a Ruby gem that moderates user-generated content by adding a simple validation to block bad words in any text field.

Simply add this to your model:

```ruby
validates :text_field, moderate: true
```

That's it! You're done.

# Why

Any text field where users can input text may be a place where bad words can be used. This gem blocks records from being created if they contain bad words.

It's good for Rails applications where you need to maintain a clean and respectful environment in comments, posts, or any other user input.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'moderate'
```

And then execute:

```bash
bundle install
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/moderate. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
