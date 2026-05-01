# 第 50 部分：收尾清扫，第 1 部分

我们现在显然已经进入了“收尾清扫（mopping up）”阶段。
因为在编译器编写之旅的这一部分里，
我不会引入什么大型新特性。
相反，
我只是修掉几个问题，
再补上几个小功能。

## 连续的 `case`

目前编译器还没法解析下面这种写法：

```c
  switch(x) {
    case 1:
    case 2: printf("Hello\n");
  }
```

原因是：
解析器在 `':'` token 后面
总是期待立刻出现一个复合语句。
在 `stmt.c` 的 `switch_statement()` 中，
原本是这样：

```c
        // Scan the ':' and get the compound expression
        match(T_COLON, ":");
        left= compound_statement(1); casecount++;
        ...
        // Build a sub-tree with the compound statement as the left child
        casetail->right= mkastunary(ASTop, 0, left, NULL, casevalue);
```

我们真正想要的是：
允许出现“空的复合语句”，
这样一来，
没有语句体的 `case`
就会自然落入下一个真正存在语句体的 `case`。

所以 `switch_statement()` 的改动变成了：

```c
        // Scan the ':' and increment the casecount
        match(T_COLON, ":");
        casecount++;

        // If the next token is a T_CASE, the existing case will fall
        // into the next case. Otherwise, parse the case body.
        if (Token.token == T_CASE) 
          body= NULL;
        else
          body= compound_statement(1);
```

不过这还只是故事的一半。
在后面的代码生成阶段，
我们还得识别这种 `NULL` 语句体，
并正确处理它。
于是在 `gen.c` 的 `genSWITCH()` 中，
现在会这样做：

```c
  // Walk the right-child linked list to
  // generate the code for each case
  for (i = 0, c = n->right; c != NULL; i++, c = c->right) {
    ...
    // Generate the case code. Pass in the end label for the breaks.
    // If case has no body, we will fall into the following body.
    if (c->left) genAST(c->left, NOLABEL, NOLABEL, Lend, 0);
    genfreeregs(NOREG);
  }
```

所以这一项修复其实相当简单直接。
对应的测试程序是 `tests/input123.c`，
用来确认这项改动确实工作正常。

## 打印符号表

前面我在排查
为什么全局变量 `Text`
对编译器自己来说居然“不可见”时，
顺手在 `sym.c` 里加了一个功能：
在每个源文件处理结束时，
把当前符号表打印出来。

现在有一个命令行参数 `-M`
可以启用这个功能。
代码细节我就不展开讲了，
先看一个输出例子：

```
Symbols for misc.c
Global
--------
void exit(): global, 1 params
    int status: param, size 4
void _Exit(): global, 1 params
    int status: param, size 4
void *malloc(): global, 1 params
    int size: param, size 4
...
int Line: extern, size 4
int Putback: extern, size 4
struct symtable *Functionid: extern, size 8
char **Infile: extern, size 8
char **Outfile: extern, size 8
char *Text[]: extern, 513 elems, size 513
struct symtable *Globhead: extern, size 8
struct symtable *Globtail: extern, size 8
...
struct mkastleaf *mkastleaf(): global, 4 params
    int op: param, size 4
    int type: param, size 4
    struct symtable *sym: param, size 8
    int intvalue: param, size 4
...
Enums
--------
int (null): enumtype, size 0
int TEXTLEN: enumval, value 512
int (null): enumtype, size 0
int T_EOF: enumval, value 0
int T_ASSIGN: enumval, value 1
int T_ASPLUS: enumval, value 2
int T_ASMINUS: enumval, value 3
int T_ASSTAR: enumval, value 4
int T_ASSLASH: enumval, value 5
...
Typedefs
--------
long size_t: typedef, size 0
char *FILE: typedef, size 0
```

## 把数组作为参数传递

我做了下面这个改动，
但事后回头看，
我觉得自己大概还是得重新思考“数组到底该怎么处理”这件事。
不过先说眼前这个问题。

当我用编译器去编译 `decl.c` 时，
会得到这样的错误：

```
Unknown variable:Text on line 87 of decl.c
```

这也是我后来写出“打印符号表”功能的直接原因。
因为 `Text`
明明就在全局符号表里，
那为什么解析器还会抱怨说它不存在？

答案在于：
`expr.c` 里的 `postfix()`
在找到一个标识符之后，
会接着看它后面的 token。
如果后面是 `'['`，
那这个标识符就必须被当作数组；
如果后面不是 `'['`，
那它就必须是普通变量：

```c
  // A variable. Check that the variable exists.
  if ((varptr = findsymbol(Text)) == NULL || varptr->stype != S_VARIABLE)
    fatals("Unknown variable", Text);
```

这就阻止了“把数组引用作为参数传给函数”这件事。
引发这个错误的“罪魁祸首”代码
就在 `decl.c` 里：

```c
      type = type_of_typedef(Text, ctype);
```

这里我们实际上是在把 `Text`
这个数组基址的地址
作为参数传进去。
但因为它后面没有跟 `'['`，
编译器就认定它应该是一个标量变量，
结果一查又发现根本没有名叫 `Text`
的标量变量，
于是就报错了。

我现在做的改动是：
允许这里接受 `S_ARRAY`
以及 `S_VARIABLE`。
不过这其实只是更大问题的冰山一角：
在我们的编译器里，
数组和指针远没有做到“像它们本该那样可互换”。
下一部分我就要去处理这个问题。

## 缺失的运算符

实际上，
从这段旅程的第 21 部分开始，
我们的编译器里就已经有下面这些 token 和 AST 运算符了：

 + <code>&#124;&#124;</code>, T_LOGOR, A_LOGOR
 + `&&`, T_LOGAND, A_LOGAND

结果我居然一直都没把它们真正实现出来！
所以现在该补上了。

对于 `A_LOGAND`，
我们有两个表达式。
如果它们都为真，
那就需要把某个寄存器设置成右值 1；
否则设成 0。

对于 `A_LOGOR`，
只要两个表达式中任意一个为真，
也要把某个寄存器设置成右值 1；
否则设成 0。

`expr.c` 里的 `binexpr()`
其实本来就已经能解析这些 token，
也会构造出 `A_LOGOR` 和 `A_LOGAND` 的 AST 节点。
所以这次真正需要修的是代码生成器。

现在在 `gen.c` 的 `genAST()` 中，
我们加上了：

```c
  case A_LOGOR:
    return (cglogor(leftreg, rightreg));
  case A_LOGAND:
    return (cglogand(leftreg, rightreg));
```

而对应的两个函数则写在 `cg.c` 中。
在看 `cg.c` 里的实现之前，
先看一个简单 C 表达式
以及它会生成的汇编：

```c
int x, y, z;
  ...
  z= x || y;
```

编译出来之后会变成：

```
        movslq  x(%rip), %r10           # Load x's rvalue
        movslq  y(%rip), %r11           # Load y's rvalue
        test    %r10, %r10              # Test x's boolean value
        jne     L13                     # True, jump to L13
        test    %r11, %r11              # Test y's boolean value
        jne     L13                     # True, jump to L13
        movq    $0, %r10                # Neither true, set %r10 to false
        jmp     L14                     # and jump to L14
L13:
        movq    $1, %r10                # Set %r10 to true
L14:
        movl    %r10d, z(%rip)          # Save boolean result to z
```

我们会分别测试两个表达式，
根据布尔结果跳转，
最终再把 0 或 1 写进结果寄存器。
`A_LOGAND` 的汇编逻辑也类似，
只是条件跳转会换成 `je`
（即为零时跳转），
并且 `movq $0` 和 `movq $1`
的位置会对调。

所以，
不再多解释，
直接把新的 `cg.c` 函数贴出来：

```c
// Logically OR two registers and return a
// register with the result, 1 or 0
int cglogor(int r1, int r2) {
  // Generate two labels
  int Ltrue = genlabel();
  int Lend = genlabel();

  // Test r1 and jump to true label if true
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r1], reglist[r1]);
  fprintf(Outfile, "\tjne\tL%d\n", Ltrue);

  // Test r2 and jump to true label if true
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r2], reglist[r2]);
  fprintf(Outfile, "\tjne\tL%d\n", Ltrue);

  // Didn't jump, so result is false
  fprintf(Outfile, "\tmovq\t$0, %s\n", reglist[r1]);
  fprintf(Outfile, "\tjmp\tL%d\n", Lend);

  // Someone jumped to the true label, so result is true
  cglabel(Ltrue);
  fprintf(Outfile, "\tmovq\t$1, %s\n", reglist[r1]);
  cglabel(Lend);
  free_register(r2);
  return(r1);
}
```

```c
// Logically AND two registers and return a
// register with the result, 1 or 0
int cglogand(int r1, int r2) {
  // Generate two labels
  int Lfalse = genlabel();
  int Lend = genlabel();

  // Test r1 and jump to false label if not true
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r1], reglist[r1]);
  fprintf(Outfile, "\tje\tL%d\n", Lfalse);

  // Test r2 and jump to false label if not true
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r2], reglist[r2]);
  fprintf(Outfile, "\tje\tL%d\n", Lfalse);

  // Didn't jump, so result is true
  fprintf(Outfile, "\tmovq\t$1, %s\n", reglist[r1]);
  fprintf(Outfile, "\tjmp\tL%d\n", Lend);

  // Someone jumped to the false label, so result is false
  cglabel(Lfalse);
  fprintf(Outfile, "\tmovq\t$0, %s\n", reglist[r1]);
  cglabel(Lend);
  free_register(r2);
  return(r1);
}
```

对应的测试程序是 `tests/input122.c`，
用来确认这项新功能已经正常工作。

## 总结与下一步

这一部分里，
我们修掉了几样零碎的小东西。
接下来我要做的是：
退后一步，
重新思考数组 / 指针设计，
并在下一部分的编译器编写之旅里
尝试把这一块修正好。 [下一步](../51_Arrays_pt2/Readme.md)
