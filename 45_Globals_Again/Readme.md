# 第 45 部分：重新审视全局变量声明

两部分之前，
我还在试着编译下面这一行代码：

```c
enum { TEXTLEN = 512 };         // Length of identifiers in input
extern char Text[TEXTLEN + 1];
```

然后我才发现：
我们当前的声明解析代码，
只能处理“数组大小是单个整数字面量”的情况。
但上面这份编译器源码里，
数组大小用到的却是一个由两个整数字面量构成的表达式。

而在上一部分里，
我已经给编译器加上了常量折叠，
这样一来，
只要表达式全部由整数字面量组成，
它最终就能被折叠成一个单独的整数字面量。

所以现在，
我们需要把之前那些手写的、
围绕字面量和 cast 的解析代码统统扔掉，
改成直接调用表达式解析器，
拿到 AST，
再从中取出折叠后的字面量值。

## 保留还是丢掉 `parse_literal()`？

在当前的 `decl.c` 中，
我们有一个叫 `parse_literal()`
的函数，
负责手工解析字符串和整数字面量。
那现在该怎么办？
是保留它，
还是干脆把它扔掉，
在别处手工调用 `binexpr()`？

我最后决定保留这个函数，
但把原有实现几乎全部清空，
顺便稍微调整一下它的职责。
它现在不仅负责解析字面量，
还负责处理：
如果一个“由多个字面量构成的表达式”前面
带了 cast，
那这个 cast 也一并吃进去。

于是 `decl.c` 里，
这个函数的声明现在变成了：

```c
// Given a type, parse an expression of literals and ensure
// that the type of this expression matches the given type.
// Parse any type cast that precedes the expression.
// If an integer literal, return this value.
// If a string literal, return the label number of the string.
int parse_literal(int type);
```

所以从接口上看，
它依旧是旧版 `parse_literal()`
的一个可直接替换版本。
只不过此前我们手工处理 cast 的那部分代码，
现在都可以丢掉了。
下面来看新的实现。

```c
int parse_literal(int type) {
  struct ASTnode *tree;

  // Parse the expression and optimise the resulting AST tree
  tree= optimise(binexpr(0));
```

看到了吧。
这里我们直接调用 `binexpr()`
去解析当前输入位置上的整个表达式，
然后再调用 `optimise()`
把其中所有字面量表达式折叠掉。

接下来，
如果这棵树能被用来做全局初始化，
那它的根节点应该只会是：
`A_INTLIT`、`A_STRLIT`，
或者 `A_CAST`
（如果前面带了 cast）。

```c
  // If there's a cast, get the child and
  // mark it as having the type from the cast
  if (tree->op == A_CAST) {
    tree->left->type= tree->type;
    tree= tree->left;
  }
```

如果根节点是 cast，
那我们就把 `A_CAST` 这个外壳剥掉，
但保留它给子节点带来的目标类型。


```c
  // The tree must now have an integer or string literal
  if (tree->op != A_INTLIT && tree->op != A_STRLIT)
    fatal("Cannot initialise globals with a general expression");
```

如果走到这里，
发现它既不是整数字面量也不是字符串字面量，
那说明这棵树不能用来初始化全局变量，
直接报错并终止。

```c
  // If the type is char * and
  if (type == pointer_to(P_CHAR)) {
    // We have a string literal, return the label number
    if (tree->op == A_STRLIT)
      return(tree->a_intvalue);
    // We have a zero int literal, so that's a NULL
    if (tree->op == A_INTLIT && tree->a_intvalue==0)
      return(0);
  }
```

我们必须支持下面这两种输入：

```c
              char *c= "Hello";
              char *c= (char *)0;
```

所以上面两个内部 `if`
正好分别对应这两种情况。
如果不是字符串字面量的话，
那就继续往下看：

```c
  // We only get here with an integer literal. The input type
  // is an integer type and is wide enough to hold the literal value
  if (inttype(type) && typesize(type, NULL) >= typesize(tree->type, NULL))
    return(tree->a_intvalue);

  fatal("Type mismatch: literal vs. variable");
  return(0);    // Keep -Wall happy
}
```

这一段我想了挺久。
因为我们必须正确处理下面这些例子：

```c
  long  x= 3;    // allow this, where 3 is type char
  char  y= 4000; // prevent this, where 4000 is too wide
  char *z= 4000; // prevent this, as z is not integer type
```

所以上面那个 `if`
会去检查：
目标类型是不是整数类型，
以及它的宽度是否足够容纳当前这个整数字面量。

## `decl.c` 中其它解析修改

既然现在我们已经有了一个新版本的 `parse_literal()`，
它既能解析字面量表达式，
又能顺手处理前置 cast，
那就该在真正的声明解析代码里用起来了。
也就是在这里，
我们把旧版手工 cast 解析代码彻底删掉并替换掉。
改动如下：

```c
// Parse a scalar declaration
static struct symtable *scalar_declaration(...) {
    ...
    // Globals must be assigned a literal value
    if (class == C_GLOBAL) {
      // Create one initial value for the variable and
      // parse this value
      sym->initlist= (int *)malloc(sizeof(int));
      sym->initlist[0]= parse_literal(type);
    }
    ...
}

// Parse an array declaration
static struct symtable *array_declaration(...) {

  ...
  // See we have an array size
  if (Token.token != T_RBRACKET) {
    nelems= parse_literal(P_INT);
    if (nelems <= 0)
      fatald("Array size is illegal", nelems);
  }

  ...
  // Get the list of initial values
  while (1) {
    ...
    initlist[i++]= parse_literal(type);
    ...
  }
  ...
}
```

这样一改，
我们大概删掉了 20 到 30 行代码，
这些原本都是为了处理“旧版 `parse_literal()` 前面可能存在的 cast”。
当然，
别忘了：
为了省掉这 30 行，
我们可是先写了差不多 100 行常量折叠代码！

不过没关系，
因为常量折叠不仅在这里会被用到，
它对一般表达式优化也同样有价值，
所以总体上依然是赚的。

## 对 `expr.c` 的一处修改

为了配合新的 `parse_literal()`，
编译器里还有一个地方必须改。
那就是通用表达式解析函数 `binexpr()`，
它现在必须知道：
有些表达式会在 `'}'` 处结束，
比如这里：

```c
  int fred[]= { 1, 2, 6 };
```

所以 `binexpr()` 里的小改动如下：

```c
    // If we hit a terminating token, return just the left node
    tokentype = Token.token;
    if (tokentype == T_SEMI || tokentype == T_RPAREN ||
        tokentype == T_RBRACKET || tokentype == T_COMMA ||
        tokentype == T_COLON || tokentype == T_RBRACE) {    // T_RBRACE is new
      left->rvalue = 1;
      return (left);
    }
```

## 用来测试这些改动的代码

我们现有的测试，
已经能覆盖“单个字面量初始化全局变量”的场景。
而 `tests/input112.c`
则同时测试了：
一个用字面量表达式初始化的标量变量，
以及一个用字面量表达式作为数组大小的声明：

```c
#include <stdio.h>
char* y = NULL;
int x= 10 + 6;
int fred [ 2 + 3 ];

int main() {
  fred[2]= x;
  printf("%d\n", fred[2]);
  return(0);
}
```

## 总结与下一步

在编译器编写之旅的下一部分中，
我大概会继续把更多编译器自身源码
喂给它自己，
看看还有哪些东西仍然没有实现。 [下一步](../46_Void_Functions/Readme.md)
