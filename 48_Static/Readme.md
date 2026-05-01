# 第 48 部分：`static` 的一个子集

在一个真正的 C 编译器里，
`static` 相关的东西大致有三类：

 + `static` 函数，它们的声明只在当前函数所在的源文件内可见；
 + `static` 全局变量，它们的声明也只在当前变量所在的源文件内可见；以及
 + `static` 局部变量，它们的行为像全局变量一样会跨函数调用保留值，
   但每个 `static` 局部变量又只在定义它的那个函数内可见。

前两类按理说都不难实现：

  + 声明时把它们当作全局对象加入符号表；
  + 等当前源文件处理结束后，再把它们从全局符号表里移除。

第三类就麻烦得多。
来看一个例子。
假设我们想保留两个私有计数器，
并各自提供一个函数去递增它们：

```c
int inc_counter1(void) {
  static int counter= 0;
  return(counter);
}

int inc_counter2(void) {
  static int counter= 0;
  return(counter);
}

```

这两个函数各自都只能看到自己的 `counter` 变量，
而且这两个计数器的值
又都会跨函数调用持续存在。
这种“值会持久化”的特性让它们像全局变量，
但“只对一个函数可见”这一点
又让它们看起来有点像局部变量。

我在这里先顺手丢一个
[闭包（closure）](https://en.wikipedia.org/wiki/Closure_(computer_programming))
的链接，
不过理论部分有点超出当前范围，
更何况我
*并不打算*
实现这第三类 `static`。

为什么？
主要是因为这种东西
同时兼具全局和局部特征，
实现起来会比较别扭。
另外，
在现在的编译器源码里，
我已经没有任何 `static` 局部变量了
（我前面重写过一些代码），
所以也没有现实需求逼着我非做不可。

因此，
这一部分里我们只专注于：
`static` 全局函数，
以及 `static` 全局变量。

## 新关键字与 token

我们新增了一个关键字 `static`，
以及一个新 token：`T_STATIC`。
具体扫描器里的改动，
照例请直接去看 `scan.c`。

## 解析 `static`

`static` 关键字的解析位置
和 `extern` 是同一个地方。
同时，
我们还希望拒绝任何在局部上下文中使用 `static`
的尝试。
所以在 `decl.c` 中，
我把 `parse_type()` 改成了这样：

```c
// Parse the current token and return a primitive type enum value,
// a pointer to any composite type and possibly modify
// the class of the type.
int parse_type(struct symtable **ctype, int *class) {
  int type, exstatic = 1;

  // See if the class has been changed to extern or static
  while (exstatic) {
    switch (Token.token) {
      case T_EXTERN:
        if (*class == C_STATIC)
          fatal("Illegal to have extern and static at the same time");
        *class = C_EXTERN;
        scan(&Token);
        break;
      case T_STATIC:
        if (*class == C_LOCAL)
          fatal("Compiler doesn't support static local declarations");
        if (*class == C_EXTERN)
          fatal("Illegal to have extern and static at the same time");
        *class = C_STATIC;
        scan(&Token);
        break;
      default:
        exstatic = 0;
    }
  }
  ...
}
```

如果看到 `static` 或 `extern`，
首先就根据当前声明类别
检查这种组合是否合法；
然后再去更新 `class` 变量。
如果两个都没看到，
那就退出这个循环。

现在的问题是：
一旦某个类型已经被标记成 `static` 声明，
那它后续要怎样被加入全局符号表？

答案是：
我们需要在编译器几乎所有用到 `C_GLOBAL`
的地方，
都把 `C_STATIC` 一并考虑进去。
这会牵涉多个文件中的不少位置，
但你可以重点留意类似这样的代码：

```c
    if (class == C_GLOBAL || class == C_STATIC) ...
```

它们会出现在 `cg.c`、`decl.c`、`expr.c`
和 `gen.c` 中。

## 清理 `static` 声明

当我们完成对这些 `static` 声明的解析之后，
接下来还得把它们从全局符号表中移除。
在 `main.c` 的 `do_compile()` 中，
现在会在关闭输入文件之后
多做一步：

```c
  genpreamble();                // Output the preamble
  global_declarations();        // Parse the global declarations
  genpostamble();               // Output the postamble
  fclose(Outfile);              // Close the output file
  freestaticsyms();             // Free any static symbols in the file
```

那我们再来看 `sym.c` 中的 `freestaticsyms()`。
它会遍历全局符号表，
对每一个 `static` 节点，
重新连一下链表把它摘掉。
我并不是链表代码高手，
所以我先在纸上把所有可能情况都列了一遍，
最后写出了下面这段：

```c
// Remove all static symbols from the global symbol table
void freestaticsyms(void) {
  // g points at current node, prev at the previous one
  struct symtable *g, *prev= NULL;

  // Walk the global table looking for static entries
  for (g= Globhead; g != NULL; g= g->next) {
    if (g->class == C_STATIC) {

      // If there's a previous node, rearrange the prev pointer
      // to skip over the current node. If not, g is the head,
      // so do the same to Globhead
      if (prev != NULL) prev->next= g->next;
      else Globhead->next= g->next;

      // If g is the tail, point Globtail at the previous node
      // (if there is one), or Globhead
      if (g == Globtail) {
        if (prev != NULL) Globtail= prev;
        else Globtail= Globhead;
      }
    }
  }

  // Point prev at g before we move up to the next node
  prev= g;
}
```

整体效果就是：
把 `static` 声明先当作普通全局声明来处理，
但在当前输入文件处理结束时，
再把它们从符号表中清掉。

## 测试这些改动

这一部分有三个测试程序，
分别是 `tests/input116.c`
到 `tests/input118.c`。
先看第一个：

```c
#include <stdio.h>

static int counter=0;
static int fred(void) { return(counter++); }

int main(void) {
  int i;
  for (i=0; i < 5; i++)
    printf("%d\n", fred());
  return(0);
}
```

再看看它对应的一小段汇编输出：

```
        ...
        .data
counter:
        .long   0
        .text
fred:
        pushq   %rbp
        movq    %rsp, %rbp
        addq    $0,%rsp
        ...
```

正常情况下，
`counter` 和 `fred`
前面本来都应该会带一个 `.globl` 标记。
而现在它们是 `static`，
所以依然会生成标签，
但我们不会再要求汇编器把它们作为全局可见符号导出。

## 总结与下一步

我原本对 `static` 挺发怵的，
但在决定“不实现最难的那第三类 `static`”
之后，
事情其实没有想象中那么糟。
真正让我头疼的是：
得在整套代码里到处翻找 `C_GLOBAL` 的使用点，
并确保合适的位置都补上 `C_STATIC` 的处理。

在编译器编写之旅的下一部分中，
我想差不多该去处理
[三元运算符（ternary operator）](https://en.wikipedia.org/wiki/%3F:) 了。 [下一步](../49_Ternary/Readme.md)
