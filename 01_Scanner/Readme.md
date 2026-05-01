# 第 1 部分：词法扫描（Lexical Scanning）简介

我们的编译器编写之旅从一个简单的词法扫描器开始。
正如我在上一部分中提到的，扫描器的工作是识别输入语言中的词法元素，也就是 *token*。

我们先从一门只包含五种词法元素的语言开始：

 + 四个基本数学运算符：`*`、`/`、`+` 和 `-`
 + 由一个或多个数字 `0` .. `9` 组成的十进制整数

我们扫描到的每个 token 都会存放在下面这个结构体中
（定义于 `defs.h`）：

```c
// Token structure
struct token {
  int token;
  int intvalue;
};
```

其中 `token` 字段可以取下面这些值之一（同样来自 `defs.h`）：

```c
// Tokens
enum {
  T_PLUS, T_MINUS, T_STAR, T_SLASH, T_INTLIT
};
```

当 token 是 `T_INTLIT`（也就是整数字面量）时，
`intvalue` 字段保存我们扫描出来的整数值。

## `scan.c` 里的函数

`scan.c` 文件里放着词法扫描器的相关函数。
我们将从输入文件中一次读入一个字符。
不过有时候我们会读得太靠前，因此需要把某个字符“放回去”。
我们还希望跟踪当前所在的行号，以便在调试信息中打印行号。
这些工作都是由 `next()` 函数完成的：

```c
// Get the next character from the input file.
static int next(void) {
  int c;

  if (Putback) {                // Use the character put
    c = Putback;                // back if there is one
    Putback = 0;
    return c;
  }

  c = fgetc(Infile);            // Read from input file
  if ('\n' == c)
    Line++;                     // Increment line count
  return c;
}
```

`Putback` 和 `Line` 变量定义在 `data.h` 中，
同时那里还定义了输入文件指针：

```c
extern_ int     Line;
extern_ int     Putback;
extern_ FILE    *Infile;
```

所有 C 文件都会包含这个头文件，此时 `extern_` 会被替换为 `extern`。
但在 `main.c` 里，`extern_` 不会展开为 `extern`；
因此这些变量“归属于” `main.c`。

最后，怎样把一个字符放回输入流呢？做法如下：

```c
// Put back an unwanted character
static void putback(int c) {
  Putback = c;
}
```

## 忽略空白字符

我们需要一个函数，用来连续读取并静默跳过空白字符，
直到拿到一个非空白字符，然后把它返回：

```c
// Skip past input that we don't need to deal with, 
// i.e. whitespace, newlines. Return the first
// character we do need to deal with.
static int skip(void) {
  int c;

  c = next();
  while (' ' == c || '\t' == c || '\n' == c || '\r' == c || '\f' == c) {
    c = next();
  }
  return (c);
}
```

## 扫描 token：`scan()`

现在我们已经可以在读取字符的同时跳过空白，
也能在读得太靠前时把字符放回去。
于是我们就可以写出第一个词法扫描器：

```c
// Scan and return the next token found in the input.
// Return 1 if token valid, 0 if no tokens left.
int scan(struct token *t) {
  int c;

  // Skip whitespace
  c = skip();

  // Determine the token based on
  // the input character
  switch (c) {
  case EOF:
    return (0);
  case '+':
    t->token = T_PLUS;
    break;
  case '-':
    t->token = T_MINUS;
    break;
  case '*':
    t->token = T_STAR;
    break;
  case '/':
    t->token = T_SLASH;
    break;
  default:
    // More here soon
  }

  // We found a token
  return (1);
}
```

这就是最简单的单字符 token 处理方式：
对每个识别出来的字符，把它转换成一个 token。
你可能会问：为什么不直接把识别出的字符存进 `struct token` 里？
答案是，后面我们还需要识别多字符 token，比如 `==`，
以及像 `if`、`while` 这样的关键字。
因此预先准备一套枚举型 token 值会让后续实现更轻松。

## 整数字面量

实际上，我们现在已经碰到了这种情况，因为我们还需要识别像 `3827`
和 `87731` 这样的整数字面量。下面就是 `switch` 语句中缺失的
`default` 代码：

```c
  default:

    // If it's a digit, scan the
    // literal integer value in
    if (isdigit(c)) {
      t->intvalue = scanint(c);
      t->token = T_INTLIT;
      break;
    }

    printf("Unrecognised character %c on line %d\n", c, Line);
    exit(1);
```

当我们遇到一个十进制数字字符时，就调用辅助函数 `scanint()`，
并把这个首字符传进去。它会返回扫描到的整数值。
为了做到这一点，它必须逐个读取字符，检查它是不是合法数字，
然后把最终数字一步步构建出来。代码如下：

```c
// Scan and return an integer literal
// value from the input file.
static int scanint(int c) {
  int k, val = 0;

  // Convert each character into an int value
  while ((k = chrpos("0123456789", c)) >= 0) {
    val = val * 10 + k;
    c = next();
  }

  // We hit a non-integer character, put it back.
  putback(c);
  return val;
}
```

一开始 `val` 为 0。每次读到 `0` 到 `9` 之间的字符时，
我们就通过 `chrpos()` 把它转换成对应的 `int` 值。
然后把 `val` 乘以 10，再把新数字加上去。

例如，如果字符序列是 `3`、`2`、`8`，那么计算过程如下：

 + `val= 0 * 10 + 3`，也就是 3
 + `val= 3 * 10 + 2`，也就是 32
 + `val= 32 * 10 + 8`，也就是 328

最后你可能注意到了 `putback(c)` 这一行。
这说明我们此时读到了一个不是十进制数字的字符。
我们不能直接把它丢掉，但幸运的是，可以把它放回输入流，
留到后面再消费。

你也可能会问：为什么不直接用 `c` 减去字符 `'0'` 的 ASCII 值，
把它变成整数呢？答案是，后面我们还能用
`chrpos("0123456789abcdef")` 这样的方式来转换十六进制数字。

下面就是 `chrpos()` 的代码：

```c
// Return the position of character c
// in string s, or -1 if c not found
static int chrpos(char *s, int c) {
  char *p;

  p = strchr(s, c);
  return (p ? p - s : -1);
}
```

到这里，`scan.c` 中当前版本的词法扫描器代码就介绍完了。

## 让扫描器真正工作起来

`main.c` 里的代码会真正调用上面的扫描器。
`main()` 函数先打开一个文件，然后从中扫描 token：

```c
void main(int argc, char *argv[]) {
  ...
  init();
  ...
  Infile = fopen(argv[1], "r");
  ...
  scanfile();
  exit(0);
}
```

而 `scanfile()` 会在还能拿到新 token 时不断循环，
并打印每个 token 的详细信息：

```c
// List of printable tokens
char *tokstr[] = { "+", "-", "*", "/", "intlit" };

// Loop scanning in all the tokens in the input file.
// Print out details of each token found.
static void scanfile() {
  struct token T;

  while (scan(&T)) {
    printf("Token %s", tokstr[T.token]);
    if (T.token == T_INTLIT)
      printf(", value %d", T.intvalue);
    printf("\n");
  }
}
```

## 一些示例输入文件

我提供了一些示例输入文件，这样你就能看到扫描器在每个文件中识别出了哪些 token，
以及它会拒绝哪些输入文件。

```
$ make
cc -o scanner -g main.c scan.c

$ cat input01
2 + 3 * 5 - 8 / 3

$ ./scanner input01
Token intlit, value 2
Token +
Token intlit, value 3
Token *
Token intlit, value 5
Token -
Token intlit, value 8
Token /
Token intlit, value 3

$ cat input04
23 +
18 -
45.6 * 2
/ 18

$ ./scanner input04
Token intlit, value 23
Token +
Token intlit, value 18
Token -
Token intlit, value 45
Unrecognised character . on line 3
```

## 总结与下一步

我们已经迈出了第一步，写出了一个简单的词法扫描器，
它能够识别四个主要的数学运算符以及整数字面量。
我们也看到，为了正确读取输入，必须跳过空白字符，
并在读得太靠前时把字符放回去。

单字符 token 很容易扫描，但多字符 token 就要麻烦一些。
不过最终，`scan()` 函数会把输入文件中的下一个 token
返回到一个 `struct token` 变量里：

```c
struct token {
  int token;
  int intvalue;
};
```

在编译器编写之旅的下一部分中，我们会构建一个递归下降（recursive descent）
解析器，用它来解释输入文件的语法，并计算并打印每个文件的最终值。 [下一步](../02_Parser/Readme.md)
