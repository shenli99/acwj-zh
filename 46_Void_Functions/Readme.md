# 第 46 部分：`void` 函数形参与扫描器改动

在编译器编写之旅的这一部分里，
我做了几项改动，
它们主要涉及扫描器和解析器。

## `void` 函数形参

先来看 C 里一个很常见的写法，
用来表示某个函数没有参数：

```c
int fred(void);         // Void means no parameters, but
int fred();             // No parameters also means no parameters
```

确实有点奇怪：
我们明明已经有一种“没有参数”的表示方式了，
却还要再来一种。
不过既然这是 C 里的常见写法，
那我们就必须支持它。

问题在于，
一旦我们读到左括号，
后面就会落入 `decl.c` 里的 `declaration_list()`。
而这个函数的设计前提是：
它要解析的是“某个类型，后面明确跟着一个标识符”。
想把它改成既支持“有标识符”
又支持“只有类型、没有标识符”，
并不轻松。
所以我们得回到 `param_declaration_list()`，
在那一层专门处理 `'void' ')'` 这个组合。

我在 `scan.c` 里原本已经有一个扫描器函数叫 `reject_token()`。
理论上它应该能做到：
先把某个 token 扫进来，
看一眼，
如果不想要它，
就把它拒绝掉；
这样下次真正扫描时，
又还能重新读到它。

不过我其实从来没真正用过这个函数，
而事实证明它本来就是坏的。
所以我退后一步想了想，
觉得更简单的办法其实是：
去 *peek* 下一枚 token。
如果发现它符合我们的需求，
再正式扫进来；
如果不符合，
那就什么都不做，
等下一次真正扫描时再正常读它。

那我们为什么需要这个能力？
因为处理参数列表中 `'void'`
的大致伪代码会是这样：

```
  parse the '('
  if the next token is 'void' {
    peek at the one after it
    if the one after 'void' is ')',
    then return zero parameters
  }
  call declaration_list() to get the real parameters
  so that 'void' is still the current token
```

之所以必须 peek，
是因为下面这两种写法都合法：

```c
int fred(void);
int jane(void *ptr, int x, int y);
```

如果我们在读到 `'void'` 之后，
真的继续把它后面的 token
正式扫进来并解析掉，
结果发现它是星号 `'*'`，
那此时 `'void'` 这个 token 就已经丢了。
接下来一旦调用 `declaration_list()`，
它看到的第一个 token 就会是 `'*'`，
然后它就会非常不高兴。

所以，
我们需要一种能力：
可以向前偷看当前 token 后面的内容，
同时又不破坏当前 token 本身。

## 新的扫描器代码

现在在 `data.h` 中，
我们有了一个新的 token 变量：

```c
extern_ struct token Token;             // Last token scanned
extern_ struct token Peektoken;         // A look-ahead token
```

而 `Peektoken.token`
会在 `main.c` 中被初始化为零。
接着我们把 `scan.c` 中主 `scan()` 函数改成这样：

```c
// Scan and return the next token found in the input.
// Return 1 if token valid, 0 if no tokens left.
int scan(struct token *t) {
  int c, tokentype;

  // If we have a lookahead token, return this token
  if (Peektoken.token != 0) {
    t->token = Peektoken.token;
    t->tokstr = Peektoken.tokstr;
    t->intvalue = Peektoken.intvalue;
    Peektoken.token = 0;
    return (1);
  }
  ...
}
```

如果 `Peektoken.token`
仍然是零，
那就照常去读取下一个 token。
但只要有东西已经提前塞进了 `Peektoken`，
那它就会成为下一次真正返回的 token。

## 声明解析上的修改

既然现在已经能向前窥视下一个 token，
那就把它用起来。
我们对 `param_declaration_list()` 的代码做了如下修改：

```c
  // Loop getting any parameters
  while (Token.token != T_RPAREN) {

    // If the first token is 'void'
    if (Token.token == T_VOID) {
      // Peek at the next token. If a ')', the function
      // has no parameters, so leave the loop.
      scan(&Peektoken);
      if (Peektoken.token == T_RPAREN) {
        // Move the Peektoken into the Token
        paramcnt= 0; scan(&Token); break;
      }
    }
    ...
    // Get the type of the next parameter
    type = declaration_list(&ctype, C_PARAM, T_COMMA, T_RPAREN, &unused);
    ...
  }
```

这里假设我们已经把 `'void'`
扫进了 `Token`。
然后通过 `scan(&Peektoken);`
去看看下一个 token 是什么，
同时又不破坏当前的 `Token`。
如果那个偷看的 token 是右括号，
那就说明这个函数没有参数；
于是把 `paramcnt` 设成零，
跳过 `'void'`，
然后直接离开循环。

但如果下一个 token 不是右括号，
那我们手里的 `Token`
仍然还是 `'void'`，
于是就可以继续调用 `declaration_list()`
去解析真正的参数列表。

## 十六进制与八进制整数常量

我之所以撞上上面这个问题，
就是因为我已经开始把编译器自己的源码
喂给它自己了。
而在修完 `'void'` 参数问题之后，
下一个暴露出来的毛病是：
编译器还不会解析像 `0x314A`
和 `0073`
这样的十六进制与八进制常量。

好在
[SubC](http://www.t3x.org/subc/)
编译器
（Nils M Holm 所写）
里已经有现成代码可借，
我几乎可以整段拿来用。
我们需要修改 `scan.c`
里的 `scanint()`：

```c
// Scan and return an integer literal
// value from the input file.
static int scanint(int c) {
  int k, val = 0, radix = 10;

  // NEW CODE: Assume the radix is 10, but if it starts with 0
  if (c == '0') {
    // and the next character is 'x', it's radix 16
    if ((c = next()) == 'x') {
      radix = 16;
      c = next();
    } else
      // Otherwise, it's radix 8
      radix = 8;

  }

  // Convert each character into an int value
  while ((k = chrpos("0123456789abcdef", tolower(c))) >= 0) {
    if (k >= radix)
      fatalc("invalid digit in integer literal", c);
    val = val * radix + k;
    c = next();
  }

  // We hit a non-integer character, put it back.
  putback(c);
  return (val);
}
```

原来这个函数里，
我们已经有一段
`k= chrpos("0123456789")`
的代码用来处理十进制字面量。
而现在，
上面新增的逻辑
会先检查是否存在前导 `'0'`。
如果有，
再去看下一个字符：
如果是 `'x'`，
就说明基数（radix）是 16；
否则就是 8。

另外还有一个变化是：
现在在累积数值时，
我们不再固定乘以 10，
而是乘以当前基数 `radix`。
这是一种非常优雅的写法，
得感谢 Nils 把它先写好了。

## 更多字符常量

接下来我又撞上的问题是：
编译器自己的代码里有这样的判断：

```c
   if (*posn == '\0')
```

而这是一种当前编译器还不认识的字符字面量。
所以我们得修改 `scan.c`
里的 `scanch()`，
让它能处理用八进制形式写出来的字符字面量。

不过，
字符字面量同样也可能用十六进制来指定，
例如 `'\0x41'`。
这时候，
SubC 的代码再次救了我们：

```c
// Read in a hexadecimal constant from the input
static int hexchar(void) {
  int c, h, n = 0, f = 0;

  // Loop getting characters
  while (isxdigit(c = next())) {
    // Convert from char to int value
    h = chrpos("0123456789abcdef", tolower(c));
    // Add to running hex value
    n = n * 16 + h;
    f = 1;
  }
  // We hit a non-hex character, put it back
  putback(c);
  // Flag tells us we never saw any hex characters
  if (!f)
    fatal("missing digits after '\\x'");
  if (n > 255)
    fatal("value out of range after '\\x'");
  return n;
}

// Return the next character from a character
// or string literal
static int scanch(void) {
  int i, c, c2;

  // Get the next input character and interpret
  // metacharacters that start with a backslash
  c = next();
  if (c == '\\') {
    switch (c = next()) {
      ...
      case '0':
      case '1':
      case '2':
      case '3':
      case '4':
      case '5':
      case '6':
      case '7':			// Code from SubC
        for (i = c2 = 0; isdigit(c) && c < '8'; c = next()) {
          if (++i > 3)
            break;
          c2 = c2 * 8 + (c - '0');
        }
        putback(c);             // Put back the first non-octal char
        return (c2);
      case 'x':
        return hexchar();	// Code from SubC
      default:
        fatalc("unknown escape sequence", c);
    }
  }
  return (c);                   // Just an ordinary old character!
}
```

这段代码同样写得很简洁漂亮。
不过从结果来看，
我们现在已经有两段做十六进制转换的代码，
以及三段做不同进制转换的代码。
所以后面在这里仍然有一些可继续重构的空间。

# 总结与下一步

这一部分里，
我们做的大多是扫描器相关改动。
它们不算什么惊天动地的大变更，
但确实都是那些必须一点点补完的细节，
否则编译器就没法真正走向自举。

接下来还有两个大块迟早得处理：
静态函数与静态变量，
以及 `sizeof()` 运算符。

在编译器编写之旅的下一部分中，
我大概会先去处理 `sizeof()`，
因为 `static` 现在对我来说还是有点吓人。 [下一步](../47_Sizeof/Readme.md)
