# 第 5 部分：语句

是时候给我们这门语言的语法加入一些“真正像样”的语句了。
我希望自己能够写出这样的代码：

```
   print 2 + 3 * 5;
   print 18 - 6/3 + 4*2;
```

当然，由于我们会忽略空白字符，
所以并不要求一个语句的所有 token 必须在同一行上。
每个语句都以关键字 `print` 开头，
并以一个分号结尾。
因此，这两样东西都会成为语言中的新 token。

## 语法的 BNF 描述

我们已经见过表达式的 BNF 写法了。
现在来定义上述这类语句的 BNF 语法：

```
statements: statement
     | statement statements
     ;

statement: 'print' expression ';'
     ;
```

一个输入文件由若干条语句构成。
它要么只包含一条语句，
要么是一条语句后面跟着更多语句。
每条语句都以关键字 `print` 开头，
后面跟一个表达式，再跟一个分号。

## 对词法扫描器的修改

在我们开始编写解析上述语法的代码之前，
需要先给已有代码补上一些新部件。
先从词法扫描器开始。

给分号增加一个 token 很容易。
至于 `print` 关键字，后面我们还会引入更多关键字，
以及变量名对应的标识符（identifier），
因此需要加入一些辅助代码来统一处理它们。

在 `scan.c` 中，我加入了下面这段从 SubC 编译器借来的代码。
它会把连续的字母数字字符读入一个缓冲区，
直到遇到非字母数字字符为止。

```c
// Scan an identifier from the input file and
// store it in buf[]. Return the identifier's length
static int scanident(int c, char *buf, int lim) {
  int i = 0;

  // Allow digits, alpha and underscores
  while (isalpha(c) || isdigit(c) || '_' == c) {
    // Error if we hit the identifier length limit,
    // else append to buf[] and get next character
    if (lim - 1 == i) {
      printf("identifier too long on line %d\n", Line);
      exit(1);
    } else if (i < lim - 1) {
      buf[i++] = c;
    }
    c = next();
  }
  // We hit a non-valid character, put it back.
  // NUL-terminate the buf[] and return the length
  putback(c);
  buf[i] = '\0';
  return (i);
}
```

我们还需要一个函数来识别语言中的关键字。
一种做法是维护一个关键字列表，
然后把 `scanident()` 读出来的缓冲区内容逐一拿去 `strcmp()`。
SubC 里的做法多了一个小优化：
先根据首字母做一次筛选，再进行 `strcmp()`。
如果关键字很多，这能更快一些。
现在我们还用不上这个优化，
但我先把它加进来，方便以后继续扩展：

```c
// Given a word from the input, return the matching
// keyword token number or 0 if it's not a keyword.
// Switch on the first letter so that we don't have
// to waste time strcmp()ing against all the keywords.
static int keyword(char *s) {
  switch (*s) {
    case 'p':
      if (!strcmp(s, "print"))
        return (T_PRINT);
      break;
  }
  return (0);
}
```

接着，在 `scan()` 的 `switch` 语句底部，
我们加入下面这段代码来识别分号和关键字：

```c
    case ';':
      t->token = T_SEMI;
      break;
    default:

      // If it's a digit, scan the
      // literal integer value in
      if (isdigit(c)) {
        t->intvalue = scanint(c);
        t->token = T_INTLIT;
        break;
      } else if (isalpha(c) || '_' == c) {
        // Read in a keyword or identifier
        scanident(c, Text, TEXTLEN);

        // If it's a recognised keyword, return that token
        if (tokentype = keyword(Text)) {
          t->token = tokentype;
          break;
        }
        // Not a recognised keyword, so an error for now
        printf("Unrecognised symbol %s on line %d\n", Text, Line);
        exit(1);
      }
      // The character isn't part of any recognised token, error
      printf("Unrecognised character %c on line %d\n", c, Line);
      exit(1);
```

我还增加了一个全局 `Text` 缓冲区，
用来保存关键字和标识符：

```c
#define TEXTLEN         512             // Length of symbols in input
extern_ char Text[TEXTLEN + 1];         // Last identifier scanned
```

## 对表达式解析器的修改

到目前为止，我们的输入文件里只包含单个表达式；
因此在 `expr.c` 中的 Pratt parser `binexpr()` 里，
曾经有下面这样一段用来结束解析的代码：

```c
  // If no tokens left, return just the left node
  tokentype = Token.token;
  if (tokentype == T_EOF)
    return (left);
```

现在，根据新语法，每个表达式都以一个分号结尾。
因此我们要修改表达式解析器，
让它在看到 `T_SEMI` token 时结束表达式解析：

```c
// Return an AST tree whose root is a binary operator.
// Parameter ptp is the previous token's precedence.
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  int tokentype;

  // Get the integer literal on the left.
  // Fetch the next token at the same time.
  left = primary();

  // If we hit a semicolon, return just the left node
  tokentype = Token.token;
  if (tokentype == T_SEMI)
    return (left);

    while (op_precedence(tokentype) > ptp) {
      ...

          // Update the details of the current token.
    // If we hit a semicolon, return just the left node
    tokentype = Token.token;
    if (tokentype == T_SEMI)
      return (left);
    }
}
```

## 对代码生成器的修改

我希望继续让 `gen.c` 中的通用代码生成器，
与 `cg.c` 中的 CPU 专用代码保持分离。
这也意味着编译器的其他部分都只能调用 `gen.c` 中的函数，
而只能由 `gen.c` 去调用 `cg.c` 中的代码。

为此，我在 `gen.c` 中定义了一些新的“前端”函数：

```c
void genpreamble()        { cgpreamble(); }
void genpostamble()       { cgpostamble(); }
void genfreeregs()        { freeall_registers(); }
void genprintint(int reg) { cgprintint(reg); }
```

## 增加语句解析器

现在新增了一个文件 `stmt.c`。
这里将存放我们语言中各类主要语句的解析代码。
目前，我们只需要处理上面给出的那套 statements 语法。
这项工作由下面这个单独的函数完成。
我把原本递归的定义改写成了一个循环：

```c
// Parse one or more statements
void statements(void) {
  struct ASTnode *tree;
  int reg;

  while (1) {
    // Match a 'print' as the first token
    match(T_PRINT, "print");

    // Parse the following expression and
    // generate the assembly code
    tree = binexpr(0);
    reg = genAST(tree);
    genprintint(reg);
    genfreeregs();

    // Match the following semicolon
    // and stop if we are at EOF
    semi();
    if (Token.token == T_EOF)
      return;
  }
}
```

在循环的每一轮中，代码都会先找到一个 `T_PRINT` token。
接着调用 `binexpr()` 解析后面的表达式。
最后，它再去匹配 `T_SEMI` token。
如果后面紧跟着的是 `T_EOF`，
我们就跳出循环。

每得到一棵表达式树，`gen.c` 里的代码就会被调用，
把这棵树转换成汇编代码，
并通过汇编里的 `printint()` 函数打印最终结果。

## 一些辅助函数

上面代码里还出现了几个新的辅助函数，
我把它们放进了新文件 `misc.c`：

```c
// Ensure that the current token is t,
// and fetch the next token. Otherwise
// throw an error 
void match(int t, char *what) {
  if (Token.token == t) {
    scan(&Token);
  } else {
    printf("%s expected on line %d\n", what, Line);
    exit(1);
  }
}

// Match a semicon and fetch the next token
void semi(void) {
  match(T_SEMI, ";");
}
```

这些函数也是解析器语法检查的一部分。
后面我还会继续添加更多这种简短的小函数来调用 `match()`，
让语法检查写起来更顺手。

## 对 `main()` 的修改

过去 `main()` 会直接调用 `binexpr()`，
去解析旧输入文件中的那个单独表达式。
现在它改成了这样：

```c
  scan(&Token);                 // Get the first token from the input
  genpreamble();                // Output the preamble
  statements();                 // Parse the statements in the input
  genpostamble();               // Output the postamble
  fclose(Outfile);              // Close the output file and exit
  exit(0);
```

## 试一试

新的和修改过的代码基本就是这些了。
下面来跑一下新版本。
这是新的输入文件 `input01`：

```
print 12 * 3;
print 
   18 - 2
      * 4; print
1 + 2 +
  9 - 5/2 + 3*5;
```

对，我就是想顺便验证一下：
即使 token 分布在多行里，也应该能正常工作。
要编译并运行这个输入文件，只需要执行 `make test`：

```make
$ make test
cc -o comp1 -g cg.c expr.c gen.c main.c misc.c scan.c stmt.c tree.c
./comp1 input01
cc -o out out.s
./out
36
10
25
```

它确实正常工作了。

## 总结与下一步

我们已经为这门语言加入了第一套“真正的”语句语法。
虽然我先用 BNF 表示了它，
但在实现时，用循环来写比递归更简单。
不用担心，我们很快又会回到递归解析上来。

在这个过程中，我们修改了扫描器，
增加了对关键字和标识符的支持，
也让通用代码生成器和 CPU 专用生成器之间的边界更清晰。

在编译器编写之旅的下一部分中，我们将为语言加入变量。
这会是一项工作量明显更大的扩展。 [下一步](../06_Variables/Readme.md)
