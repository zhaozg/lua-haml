# Lua Haml

## About

Lua Haml is an implementation of the [Haml](http://haml.info) markup
language for Lua.

A Haml language reference can be found
[here](http://haml.info/docs/yardoc/file.HAML_REFERENCE.html).

A basic haml tutorial can be found [here](http://haml.info/tutorial.html)

This repository is modified version of [here](https://github.com/norman/lua-haml)

Lua Haml implements almost 100% of Ruby Haml, and attempts to be as compatible
as possible with it, with the following exceptions:

* Your script blocks are in Lua rather than Ruby, obviously.
* A few Ruby-specific filters are not implemented, namely `:maruku`, `:ruby` and `:sass`.
* No attribute methods. This feature would have to be added to Ruby-style
  attributes which are discouraged in Lua-Haml, or the creation of a
  Lua-specific attribute format, which I don't want to add.
* No object reference. This feature is idiomatic to the Rails framework and
  doesn't really apply to Lua.
* No ugly mode. Because of how Lua Haml is designed, there's no performance
  penalty for outputting indented code, so there's no reason to implement this
  option.

Here's a [Haml
template](http://github.com/norman/lua-haml/tree/master/sample.haml) that uses
most of Lua Haml's features.

## TODO

Lua Haml is now feature complete, but is still considered beta quality. That
said, I am using it for a production website, and will work quickly to fix any
bugs that are reported.  So please feel free to use it for serious work - just
not the Space Shuttle, ok? And very welcome any patch.

## Hacking it

The [Github repository](http://github.com/zhaozg/lua-haml) is located at:

    git://github.com/zhaozg/lua-haml.git

Before run the specification test, you need install 
[lpeg module](http://www.inf.puc-rio.br/~roberto/lpeg/) and 
[json modules](https://github.com/LuaDist/dkjson)

To run test, do this:

    lua test.lua

To convert haml to html, do this:

    lua bin/luahaml sample.haml > sample.html

To run bench, do this:

    lua bench.lua sample.haml 10000

## Bug reports

Please report them on the [Github issue tracker](http://github.com/zhaozg/lua-haml/issues).

## Author

[Norman Clarke](mailto://norman@njclarke.com)

[George Zhao](https://github.com/zhaozg)

## Thanks

To Hampton Caitlin, Nathan Weizenbaum and Chris Eppstein for their work on the
original Haml. Thanks also to Daniele Alessandri for being LuaHaml's earliest
"real" user, and a source of constant encouragement.

## License

The MIT License

Copyright (c) 2009-2010 Norman Clarke

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
