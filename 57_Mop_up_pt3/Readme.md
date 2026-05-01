# 第 57 部分：收尾清扫，第 3 部分

在编译器编写之旅的这一部分里，
我又修了编译器里几个零碎但必要的小问题。

## 没有 `-D` 标志

我们的编译器目前还没有
运行时的 `-D` 标志，
也就是无法在命令行上
给预处理器定义一个符号。
要把这个能力加进来，
多少会有点复杂。
但偏偏我们在 `Makefile`
里正用着这个特性，
好把头文件目录的位置传进去。

所以我干脆把 `Makefile`
改写成直接生成一个新的头文件，
把这个目录位置写进去：

```
# Define the location of the include directory
INCDIR=/tmp/include
...

incdir.h:
        echo "#define INCDIR \"$(INCDIR)\"" > incdir.h
```

然后在 `defs.h` 里，
我们现在会这样包含它：

```c
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include "incdir.h"
```

这样一来，
源码里就能直接知道这个目录的位置了。

## 加载 `extern` 变量

我在 `include/stdio.h`
里新增了下面这三个外部变量：

```c
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;
```

但当我尝试使用它们时，
它们居然被当成了局部变量！
后来发现，
是我在选择“全局变量加载路径”时的逻辑写错了。
现在在 `gen.c` 的 `genAST()` 中，
相关代码变成了这样：

```c
    case A_IDENT:
      // Load our value if we are an rvalue
      // or we are being dereferenced
      if (n->rvalue || parentASTop == A_DEREF) {
        if (n->sym->class == C_GLOBAL || n->sym->class == C_STATIC
            || n->sym->class == C_EXTERN) {
          return (cgloadglob(n->sym, n->op));
        } else {
          return (cgloadlocal(n->sym, n->op));
        }
```

这里新增的关键分支
就是 `C_EXTERN`。

## Pratt 解析器的问题

很久以前，
在这趟旅程的第 3 部分里，
我引入了
[Pratt parser](https://en.wikipedia.org/wiki/Pratt_parser)。
它通过一张“token 对应优先级”的表来工作。
从那以后我们就一直在用它，
而且总体来说效果不错。

但后来我又陆续引入了不少
并不是直接由 Pratt parser 处理的 token：
前缀运算符、
后缀运算符、
类型转换、
数组下标访问等等。
在这个过程中，
我不小心把一条很关键的链路弄断了：
Pratt parser
不再总能正确知道“前一个运算符的优先级”。

先来看一遍基础版 Pratt 算法，
也就是 `expr.c` 中 `binexpr()`
展示出来的样子：

```c
  // Get the tree on the left.
  // Fetch the next token at the same time.
  left = prefix();
  tokentype = Token.token;

  // While the precedence of this token is more than that of the
  // previous token precedence, or it's right associative and
  // equal to the previous token's precedence
  while ((op_precedence(tokentype) > ptp) ||
         (rightassoc(tokentype) && op_precedence(tokentype) == ptp)) {
    // Fetch in the next integer literal
    scan(&Token);

    // Recursively call binexpr() with the
    // precedence of our token to build a sub-tree
    right = binexpr(OpPrec[tokentype]);

    // Join that sub-tree with ours (code not given)

    // Update the details of the current token.
    // Leave the loop if a terminating token (code not given)
    tokentype = Token.token;
  }

  // Return the tree we have when the precedence
  // is the same or lower
  return (left);
```

这里有个关键前提：
`binexpr()`
必须带着“前一个 token 的优先级”
继续往下调用。
现在来看它是怎么被弄坏的。

考虑这样一个表达式，
它用来检查三个指针是否都有效：

```c
  if (a == NULL || b == NULL || c == NULL)
```

`==` 运算符的优先级
高于 `||`，
因此 Pratt parser
应该把它看成下面这种结构：

```c
  if ((a == NULL) || (b == NULL) || (c == NULL))
```

而 `NULL`
又是这样定义的，
其中还包含了一个 cast：

```c
#define NULL (void *)0
```

所以我们沿着调用链来看一下：

 + `binexpr(0)` 从 `if_statement()` 被调用
 + `binexpr(0)` 解析到 `==`
    （它的优先级是 40），
    然后调用 `binexpr(40)`
 + `binexpr(40)` 调用 `prefix()`
 + `prefix()` 调用 `postfix()`
 + `postfix()` 调用 `primary()`
 + `primary()` 看到 `(void *)0`
    开头的左括号，
    然后调用 `paren_expression()`
 + `paren_expression()` 看到 `void` token，
    调用 `parse_cast()`。
    cast 解析完之后，
    它再调用 `binexpr(0)`
    去解析那个 `0`

问题就出在这里。
`NULL` 里的 `0`
本来仍然应该处在优先级 40 这一层上下文中，
但 `paren_expression()`
却把它直接重置回了 0。

这意味着，
我们会错误地把 `NULL || b`
先结合起来构建 AST，
而不是先把 `a == NULL`
作为一个整体去建树。

解决办法就是：
确保“前一个 token 的优先级”
能够从 `binexpr()`
一路沿着调用链传递到
`paren_expression()`。
于是现在：

 + `prefix()`、`postfix()`、`primary()` 和 `paren_expression()`

这些函数全都多接收了一个 `int ptp` 参数，
并且会继续把它往下传。

`tests/input143.c`
会检查这项修改，
验证
`if (a==NULL || b==NULL || c==NULL)`
现在已经能被正确解析。

## 指针、`+=` 和 `-=`

前面某一段时间里，
我意识到：
如果我们给一个指针加上整数值，
就必须先按“该指针所指向类型的大小”
对这个整数进行缩放。
例如：

```c
int list[]= {3, 5, 7, 9, 11, 13, 15};
int *lptr;

int main() {
  lptr= list;
  printf("%d\n", *lptr);
  lptr= lptr + 1; printf("%d\n", *lptr);
}
```

这里应该先打印出 `list`
起始位置上的值，
也就是 3。
而 `lptr`
在执行加一时，
实际增加的应该是 `int` 的 *大小*，
也就是 4，
这样它才会正确指向 `list`
中的下一个元素。

目前我们已经会对 `+` 和 `-`
做这件事，
但我忘了把同样的逻辑补到
`+=` 和 `-=` 上。
幸好这个修复很简单。
现在在 `types.c`
的 `modify_type()` 底部，
代码是这样的：

```c
  // We can scale only on add and subtract operations
  if (op == A_ADD || op == A_SUBTRACT ||
      op == A_ASPLUS || op == A_ASMINUS) {

    // Left is int type, right is pointer type and the size
    // of the original type is >1: scale the left
    if (inttype(ltype) && ptrtype(rtype)) {
      rsize = genprimsize(value_at(rtype));
      if (rsize > 1)
        return (mkastunary(A_SCALE, rtype, rctype, tree, NULL, rsize));
      else
        return (tree);          // Size 1, no need to scale
    }
  }
```

你可以看到，
我把 `A_ASPLUS`
和 `A_ASMINUS`
也加入了“允许做缩放”的运算列表中。

## 总结与下一步

这轮收尾先到这里。
而当我修 `+=` 和 `-=`
这个问题时，
它又顺手暴露出了一个更大的坑：
当 `++` 和 `--`
（无论前缀还是后缀）
作用在指针上时，
我们的处理方式有明显问题。

在编译器编写之旅的下一部分中，
我会正面解决这个问题。 [下一步](../58_Ptr_Increments/Readme.md)
