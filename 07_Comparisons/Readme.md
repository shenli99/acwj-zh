# 第 7 部分：比较运算符

我本来打算下一步直接加 `if` 语句，
但后来意识到，最好还是先把比较运算符补上。
结果证明这一步相当容易，
因为它们和现有那些运算符一样，都是二元运算符。

所以，下面我们快速看看：
要把这六个比较运算符加进来，需要改哪些地方：
`==`、`!=`、`<`、`>`、`<=` 和 `>=`。

## 加入新 token

我们将会有六个新 token，
所以先把它们加进 `defs.h`：

```c
// Token types
enum {
  T_EOF,
  T_PLUS, T_MINUS,
  T_STAR, T_SLASH,
  T_EQ, T_NE,
  T_LT, T_GT, T_LE, T_GE,
  T_INTLIT, T_SEMI, T_ASSIGN, T_IDENT,
  // Keywords
  T_PRINT, T_INT
};
```

我还重新排列了这些 token 的顺序，
让那些有优先级的 token 按从低到高的优先级排在前面，
而没有优先级的 token 则放在后面。

## 扫描这些 token

现在我们得把它们扫描出来。
注意，这里必须区分 `=` 和 `==`、`<` 和 `<=`、`>` 和 `>=`。
所以我们需要从输入中多读一个字符，
如果不需要它，就再把它放回去。
下面是 `scan.c` 中 `scan()` 的新代码：

```c
  case '=':
    if ((c = next()) == '=') {
      t->token = T_EQ;
    } else {
      putback(c);
      t->token = T_ASSIGN;
    }
    break;
  case '!':
    if ((c = next()) == '=') {
      t->token = T_NE;
    } else {
      fatalc("Unrecognised character", c);
    }
    break;
  case '<':
    if ((c = next()) == '=') {
      t->token = T_LE;
    } else {
      putback(c);
      t->token = T_LT;
    }
    break;
  case '>':
    if ((c = next()) == '=') {
      t->token = T_GE;
    } else {
      putback(c);
      t->token = T_GT;
    }
    break;
```

我还把原先 `=` 对应的 token 名字改成了 `T_ASSIGN`，
避免它和新的 `T_EQ` 混淆。

## 新的表达式代码

现在我们已经能够扫描出这六个新 token 了。
接下来就要在表达式中解析它们，
并且为它们施加正确的运算符优先级。

到这个时候，你大概已经看出来了：

  + 我正在构建一个未来会可自举的编译器
  + 目标语言是 C
  + 同时参考了 SubC 编译器

这意味着，我写的是一个足够大的 C 子集编译器
（和 SubC 一样），
它最终要能编译自己。
因此，我理应采用正常的
[C 运算符优先级顺序](https://en.cppreference.com/w/c/language/operator_precedence)。
这也就意味着，比较运算符的优先级低于乘法和除法。

我还意识到，之前那个“把 token 映射成 AST 节点类型”的
`switch` 语句只会越写越大。
所以我决定重排 AST 节点类型，
让所有二元运算符在 token 和 AST 节点之间形成 1:1 映射
（定义于 `defs.h`）：

```c
// AST node types. The first few line up
// with the related tokens
enum {
  A_ADD=1, A_SUBTRACT, A_MULTIPLY, A_DIVIDE,
  A_EQ, A_NE, A_LT, A_GT, A_LE, A_GE,
  A_INTLIT,
  A_IDENT, A_LVIDENT, A_ASSIGN
};
```

这样，在 `expr.c` 中，
我就能简化“token 转 AST 节点类型”的逻辑，
同时顺便加入新 token 的优先级定义：

```c
// Convert a binary operator token into an AST operation.
// We rely on a 1:1 mapping from token to AST operation
static int arithop(int tokentype) {
  if (tokentype > T_EOF && tokentype < T_INTLIT)
    return(tokentype);
  fatald("Syntax error, token", tokentype);
}

// Operator precedence for each token. Must
// match up with the order of tokens in defs.h
static int OpPrec[] = {
  0, 10, 10,                    // T_EOF, T_PLUS, T_MINUS
  20, 20,                       // T_STAR, T_SLASH
  30, 30,                       // T_EQ, T_NE
  40, 40, 40, 40                // T_LT, T_GT, T_LE, T_GE
};
```

这就完成了解析和运算符优先级相关的修改。

## 代码生成

由于这六个新运算符同样是二元运算符，
所以修改 `gen.c` 中的通用代码生成器也很简单：

```c
  case A_EQ:
    return (cgequal(leftreg, rightreg));
  case A_NE:
    return (cgnotequal(leftreg, rightreg));
  case A_LT:
    return (cglessthan(leftreg, rightreg));
  case A_GT:
    return (cggreaterthan(leftreg, rightreg));
  case A_LE:
    return (cglessequal(leftreg, rightreg));
  case A_GE:
    return (cggreaterequal(leftreg, rightreg));
```

## 生成 x86-64 代码

到了这里，事情稍微变得有点棘手。
在 C 里，比较运算符是有返回值的。
如果比较结果为真，就返回 1；
如果为假，就返回 0。
因此我们需要写出能正确反映这种行为的 x86-64 汇编代码。

幸运的是，x86-64 里确实有能做到这一点的指令。
不幸的是，中间还得处理一些细节。
看下面这条 x86-64 指令：

```
    cmpq %r8,%r9
```

上面的 `cmpq` 实际执行的是 `%r9 - %r8`，
并设置若干状态标志位，
其中包括负号标志（negative flag）和零标志（zero flag）。
于是我们就可以通过这些标志位的组合来判断比较结果：

| Comparison | Operation | Flags If True |
|------------|-----------|---------------|
| %r8 == %r9 | %r9 - %r8 |  Zero         |
| %r8 != %r9 | %r9 - %r8 |  Not Zero     |
| %r8 > %r9  | %r9 - %r8 |  Not Zero, Negative |
| %r8 < %r9  | %r9 - %r8 |  Not Zero, Not Negative |
| %r8 >= %r9 | %r9 - %r8 |  Zero or Negative |
| %r8 <= %r9 | %r9 - %r8 |  Zero or Not Negative |

x86-64 提供了六条指令，
可以根据这两个标志位把寄存器设置成 1 或 0：
按照上表的顺序分别是 `sete`、`setne`、`setg`、`setl`、`setge`
和 `setle`。

问题在于，这些指令只会设置寄存器的最低一个字节。
如果寄存器在更高位上原本还有其他位被置位，
它们会保持不变。
那样一来，我们本来想把变量设成 1，
但如果它原本的十进制值是 1000，
结果就会变成 1001，这显然不对。

解决办法是在执行 `setX` 指令之后，
再用 `andq` 把不需要的高位全部清掉。
在 `cg.c` 中，有一个通用比较函数就是这么做的：

```c
// Compare two registers.
static int cgcompare(int r1, int r2, char *how) {
  fprintf(Outfile, "\tcmpq\t%s, %s\n", reglist[r2], reglist[r1]);
  fprintf(Outfile, "\t%s\t%s\n", how, breglist[r2]);
  fprintf(Outfile, "\tandq\t$255,%s\n", reglist[r2]);
  free_register(r1);
  return (r2);
}
```

其中 `how` 就是那些 `setX` 指令之一。
注意，我们这里执行的是

```
   cmpq reglist[r2], reglist[r1]
```

因为它实际表示的是 `reglist[r1] - reglist[r2]`，
而这正是我们真正想比较的顺序。

## x86-64 寄存器

这里我们需要稍微岔开一下，讨论 x86-64 架构中的寄存器。
x86-64 拥有若干 64 位通用寄存器，
同时我们也可以用不同的寄存器名称来访问它们的子部分。

![](https://i.stack.imgur.com/N0KnG.png)

上面这张来自 *stack.imgur.com* 的图显示：
对于 64 位的 *r8* 寄存器，
我们可以通过 `r8d` 访问它的低 32 位。
类似地，`r8w` 表示低 16 位，
`r8b` 则表示低 8 位。

在 `cgcompare()` 中，
代码先用 `reglist[]` 数组里的名字去比较两个 64 位寄存器，
然后再用 `breglist[]` 数组里的名字，
在第二个寄存器的 8 位版本上设置结果。
x86-64 架构只允许 `setX` 指令作用在 8 位寄存器名上，
所以才需要额外准备这张 `breglist[]` 表。

## 生成多条比较指令

有了这个通用函数之后，
写出六个具体比较函数就很容易了：

```c
int cgequal(int r1, int r2) { return(cgcompare(r1, r2, "sete")); }
int cgnotequal(int r1, int r2) { return(cgcompare(r1, r2, "setne")); }
int cglessthan(int r1, int r2) { return(cgcompare(r1, r2, "setl")); }
int cggreaterthan(int r1, int r2) { return(cgcompare(r1, r2, "setg")); }
int cglessequal(int r1, int r2) { return(cgcompare(r1, r2, "setle")); }
int cggreaterequal(int r1, int r2) { return(cgcompare(r1, r2, "setge")); }
```

和其他二元运算函数一样，
其中一个寄存器会被释放，
另一个寄存器带着结果返回。

# 把它跑起来

看看 `input04` 这个输入文件：

```c
int x;
x= 7 < 9;  print x;
x= 7 <= 9; print x;
x= 7 != 9; print x;
x= 7 == 7; print x;
x= 7 >= 7; print x;
x= 7 <= 7; print x;
x= 9 > 7;  print x;
x= 9 >= 7; print x;
x= 9 != 7; print x;
```

这些比较结果全都为真，
所以最终应该打印出九个 1。
执行一次 `make test` 就能验证。

再来看看第一次比较生成的汇编代码：

```
        movq    $7, %r8
        movq    $9, %r9
        cmpq    %r9, %r8        # Perform %r8 - %r9, i.e. 7 - 9
        setl    %r9b            # Set %r9b to 1 if 7 is less than 9
        andq    $255,%r9        # Remove all other bits in %r9
        movq    %r9, x(%rip)    # Save the result in x
        movq    x(%rip), %r8
        movq    %r8, %rdi
        call    printint        # Print x out
```

没错，这段汇编现在看起来确实不算高效。
不过我们甚至都还没有开始真正考虑优化代码。
借用 Donald Knuth 的一句话：

> **Premature optimization is the root of all evil (or at least most of it)
  in programming.**

## 总结与下一步

这是一次相当轻松的编译器扩展。
但旅程的下一部分就不会这么简单了。

在编译器编写之旅的下一部分中，我们将把 `if` 语句加入编译器，
并真正用上这一部分刚刚增加的比较运算符。 [下一步](../08_If_Statements/Readme.md)
