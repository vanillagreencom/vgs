# Ashen Contributing Guidelines

First of all, thank you for contributing to Ashen! In the interest of keeping
the repository as clean and error-free as possible, there are a few general
guidelines you should keep in mind.

## Style

Please adhere to general good coding style, as well as what's defined in
[.stylua.toml](.stylua.toml).

## Type Annotations

Please try your best to include type annotations with any new code.
[LazyDev](https://github.com/folke/lazydev.nvim) can help with this.

## Commit Messages

This project requires commit messages to follow the
[conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) standard.
This is required by the release action, so please adhere to it.

Including a _scope_ with your commit messages is encouraged but not necessary.
At the end of the day, just use your common sense with them -- the point is to
make sure the automated semantic versioning release action remains intact.

## Documentation

If your changes require any documentation, please update the README. If you're
adding an extra, then please add a `README.md` to its folder containing
installation instructions.

## Tips

I recommend checking out [llscheck](https://github.com/jeffzi/llscheck) and
[luacheck](https://github.com/mpeterv/luacheck), which can both be installed via
`luarocks`. Consider making a habit of running these commands!
