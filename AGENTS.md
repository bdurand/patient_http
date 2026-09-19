## Coding style

Always include the # frozen_string_literal: true magic comment at the top of each ruby file.

Use `class << self` syntax for defining class methods. instead of `def self.method_name`.

All public methods should have YARD documentation. Include an empty comment line between the method description and the first YARD tag.

This project uses the standardrb style guide. Run `bundle exec standardrb --fix` to automatically fix style issues.

Do not rewrite existing code just to satisfy style guidelines unless those are violations of the standardrb rules.

Do not use suffixed conditionals with complex conditions with multiple logical operators. Use full `if`/`unless` blocks instead. Do not convert existing code to use suffixed conditionals if it is already using block conditionals.

Use [:symbol_1, :symbol_2] syntax instead of %i[symbol_1 symbol_2] for arrays of symbols.

Use ["string1", "string2"] syntax instead of %w[string1 string2] for single line arrays of strings.

Use double quotes for strings instead of single quotes.

Do not change existing code to break existing line length unless absolutely necessary. New code should adhere to a 100 character line length limit.

Use `raise SomeError.new("message")` instead of `raise SomeError, "message"` for raising exceptions.

Code comments and documentation should be general, to the point, and age well. They should not reference ticket numbers, or conversations, or specific conditions you encountered and then fixed when building the code. Comments and documentation should be written using ASD-STE100 Simplified Technical English. The content should be evergreen and make sense when viewed later outside the context of our conversation or the environment where the code is currently running.

## Testing

Run the test suite with `bundle exec rspec`.
