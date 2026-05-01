# 第 42 部分：类型转换（type casting）与 `NULL`

在编译器编写之旅的这一部分里，
我实现了类型转换（type casting）。
我原本以为这会让我能够直接写出：

```c
#define NULL (void *)0
```

但后来才发现，
我之前还没有把 `void *`
真正支持到可用程度。
所以这一部分里，
我不仅加入了类型转换，
也顺手把 `void *` 支持补到了能正常工作的状态。

## 什么是类型转换？

类型转换就是：
强行把某个表达式的类型改成另一种类型。
常见原因包括：
把一个整数值缩窄到更小的类型范围，
或者把某种指针类型
赋给另一种指针类型的存储位置，
例如：

```c
  int   x= 65535;
  char  y= (char)x;     // y is now 255, the lower 8 bits
  int  *a= &x;
  char *b= (char *)a;   // b point at the address of x
  long *z= (void *)0;   // z is a NULL pointer, not pointing at anything
```

注意上面这些 cast
都是出现在赋值语句里的。
对函数内部的表达式来说，
我们需要在 AST 中加入一个 `A_CAST` 节点，
表示“把原表达式类型转换成这个新类型”。

而对全局变量赋值来说，
我们则需要修改赋值解析逻辑，
让它能接受“字面量之前先来一个 cast”。

## 新函数：`parse_cast()`

我在 `decl.c` 中新增了这个函数：

```c
// Parse a type which appears inside a cast
int parse_cast(void) {
  int type, class;
  struct symtable *ctype;

  // Get the type inside the parentheses
  type= parse_stars(parse_type(&ctype, &class));

  // Do some error checking. I'm sure more can be done
  if (type == P_STRUCT || type == P_UNION || type == P_VOID)
    fatal("Cannot cast to a struct, union or void type");
  return(type);
}
```

外围那层 `'(' ... ')'`
的解析是在别处完成的。
这里我们先取出类型标识符，
再处理后面的 `'*'`，
从而得到 cast 目标类型。
然后再阻止把值 cast 成
struct、union 或 `void`。

之所以要专门抽出这个函数，
是因为表达式解析和全局变量赋值解析
都会用到它。
我不想写出任何
[DRY 反例代码](https://en.wikipedia.org/wiki/Don%27t_repeat_yourself)。

## 表达式中的 cast 解析

我们的表达式代码原本就已经会解析括号，
所以这里必须在原有基础上修改。
现在 `expr.c` 中的 `primary()` 会这样处理：

```c
static struct ASTnode *primary(void) {
  int type=0;
  ...
  switch (Token.token) {
  ...
    case T_LPAREN:
    // Beginning of a parenthesised expression, skip the '('.
    scan(&Token);


    // If the token after is a type identifier, this is a cast expression
    switch (Token.token) {
      case T_IDENT:
        // We have to see if the identifier matches a typedef.
        // If not, treat it as an expression.
        if (findtypedef(Text) == NULL) {
          n = binexpr(0); break;
        }
      case T_VOID:
      case T_CHAR:
      case T_INT:
      case T_LONG:
      case T_STRUCT:
      case T_UNION:
      case T_ENUM:
        // Get the type inside the parentheses
        type= parse_cast();

        // Skip the closing ')' and then parse the following expression
        rparen();

      default: n = binexpr(0); // Scan in the expression
    }

    // We now have at least an expression in n, and possibly a non-zero type in type
    // if there was a cast. Skip the closing ')' if there was no cast.
    if (type == 0)
      rparen();
    else
      // Otherwise, make a unary AST node for the cast
      n= mkastunary(A_CAST, type, n, NULL, 0);
    return (n);
  }
}
```

这段代码信息量不小，
所以分段解释。
上面这些 `case`
会先确保 `'('` 后面出现的是一个类型标识符。
然后调用 `parse_cast()`
取出 cast 类型，
并解析后面的 `')'`。

此时我们还没有能返回的 AST，
因为还不知道“到底要把哪个表达式 cast”。
所以流程会落到 `default` 分支，
在那里继续解析后续表达式。

等到这里时，
`type` 要么仍然是 0
（说明没有 cast），
要么已经是非零值
（说明前面确实出现了 cast）。
如果没有 cast，
那就跳过右括号，
直接返回括号里的表达式。

如果存在 cast，
那就创建一个 `A_CAST` 节点，
把新的 `type` 记录进去，
并把后面的表达式挂成它的子节点。

## 为 cast 生成汇编代码

这一步我们其实挺幸运，
因为表达式的值本来就已经会保存在寄存器里。
所以如果我们写：

```c
  int   x= 65535;
  char  y= (char)x;     // y is now 255, the lower 8 bits
```

那完全可以先把 65535 放进某个寄存器。
然后在把它存回 `y` 时，
再由左值类型去决定“该按多大的宽度写回去”。
所以最终汇编会像这样：

```
        movq    $65535, %r10            # Store 65535 in x
        movl    %r10d, -4(%rbp)
        movslq  -4(%rbp), %r10          # Get x into %r10
        movb    %r10b, -8(%rbp)         # Store one byte into y
```

因此在 `gen.c` 的 `genAST()` 中，
我们只需要这样处理 cast：

```c
  ...
  leftreg = genAST(n->left, NOLABEL, NOLABEL, NOLABEL, n->op);
  ...
  switch (n->op) {
    ...
    case A_CAST:
      return (leftreg);         // Not much to do
    ...
  }
```

## 全局赋值中的 cast

上面这些处理，
对局部变量来说完全没问题，
因为编译器本来就是把它们当作表达式来完成赋值的。
但对全局变量来说，
我们必须手工去解析 cast，
再把它应用到后面的字面量值上。

在 `parse_literal()` 中，
我现在会这样做：

```c
int parse_literal(int type) {
  int value, type2;
  ...
  // If the literal has a cast in front, parse
  // the cast type and skip the right parenthesis
  if (Token.token == T_LPAREN) {
    scan(&Token);
    type2= parse_cast();
    if (type != type2)
      fatal("Type mismatch between variable and cast");
    rparen();
  }
```

也就是说，
如果字面量前面带着 cast，
我们就先把 cast 类型解析出来，
再检查它是否和目标变量类型一致。
如果不一致就报错。

现在，
我们终于可以支持下面这样的代码了：

```c
  char *str= (void *)0;
```

尽管 `str` 的类型是 `char *`，
而不是 `void *`。

## 让 `void *` 真正工作起来

现在我们得开始处理：
`void *` 以及其它指针 / 指针之间的操作，
在表达式里到底该如何兼容。

为此，
我不得不改动 `types.c` 里的 `modify_type()`。
先回顾一下它是干什么的：

```c
// Given an AST tree and a type which we want it to become,
// possibly modify the tree by widening or scaling so that
// it is compatible with this type. Return the original tree
// if no changes occurred, a modified tree, or NULL if the
// tree is not compatible with the given type.
// If this will be part of a binary operation, the AST op is not zero.
struct ASTnode *modify_type(struct ASTnode *tree, int rtype, int op);
```

这段代码原本负责做“扩宽”处理，
例如 `int x= 'Q';`
这种情况，
会把字符值扩成 32 位。
我们也会用它来做“缩放（scaling）”，
比如：

```c
  int x[4];
  int y= x[2];
```

这里索引值 `"2"`
会按 `int` 的大小被缩放，
从而变成相对于 `x[]` 数组基址偏移 8 个字节。

所以，
在函数内部写下：

```c
  char *str= (void *)0;
```

时，
我们会得到下面这棵 AST：

```
          A_ASSIGN
           /    \
       A_CAST  A_IDENT
         /      str
     A_INTLIT
         0
```
  
此时左边这棵 `tree` 的类型是 `void *`，
而 `rtype` 会是 `char *`。
所以我们最好确保：
这种操作是被允许的。

我现在把 `modify_type()` 改成了这样来处理指针：

```c
  // For pointers
  if (ptrtype(ltype) && ptrtype(rtype)) {
    // We can compare them
    if (op >= A_EQ && op <= A_GE)
      return(tree);

    // A comparison of the same type for a non-binary operation is OK,
    // or when the left tree is of  `void *` type.
    if (op == 0 && (ltype == rtype || ltype == pointer_to(P_VOID)))
      return (tree);
  }
```

这样一来，
指针之间的比较是允许的，
但其它二元运算
（例如加法）
仍然是不合法的。

这里所谓的“非二元操作”，
指的就是赋值这一类场景。
相同类型之间的赋值当然没问题。
而现在，
我们也允许把一个 `void *`
指针赋给任意其它指针类型。

## 加入 `NULL`

既然现在已经能正确处理 `void *` 指针了，
那我们就终于可以把 `NULL`
加到头文件里。
我现在在 `stdio.h` 和 `stddef.h`
里都加入了下面这段：

```c
#ifndef NULL
# define NULL (void *)0
#endif
```

不过这里还有最后一个小弯。
当我试着写出下面这条全局声明时：

```c
#include <stdio.h>
char *str= NULL;
```

结果得到的却是：

```
str:
        .quad   L0
```

原因在于：
对 `char *` 指针来说，
每个初始化值都会被当作“某个标签号”。
于是 `NULL` 里的那个 `"0"`
就被错误地翻译成了 `"L0"` 标签。
这显然得修。

所以现在在 `cg.c` 的 `cgglobsym()` 里，
代码变成了这样：

```c
      case 8:
        // Generate the pointer to a string literal. Treat a zero value
        // as actually zero, not the label L0
        if (node->initlist != NULL && type== pointer_to(P_CHAR) && initvalue != 0)
          fprintf(Outfile, "\t.quad\tL%d\n", initvalue);
        else
          fprintf(Outfile, "\t.quad\t%d\n", initvalue);
```

是的，
这段处理看起来很丑，
但它确实能工作！

## 测试这些改动

我就不把所有测试文件逐个展开了，
不过 `tests/input101.c`
到 `tests/input108.c`
会一起覆盖上面的功能，
以及编译器的相应错误检查逻辑。

## 总结与下一步

我原本以为 cast 会很简单，
结果它本身确实不难。
真正麻烦的是围绕 `void *`
展开的那些兼容问题。
我觉得自己大部分情况都已经处理到了，
但多半还没有全部覆盖，
所以后面大概率还会继续遇到一些
我现在还没发现的 `void *` 边界情况。

在编译器编写之旅的下一部分中，
我们会补上一些缺失的运算符。 [下一步](../43_More_Operators/Readme.md)
