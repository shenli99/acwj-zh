# 第 60 部分：通过三重测试（Triple Test）

在编译器编写之旅的这一部分里，
我们将让编译器真正通过三重测试（triple test）！
我为什么这么确定？
因为我已经通过修改编译器源码里的几行代码，
让它通过了三重测试。
但我当时其实还不知道，
为什么原来的那几行代码会出错。

所以，
这一部分更像是一场调查：
我们先收集线索，
推断问题，
修复它，
最后让编译器真正正确地通过三重测试。

至少，
我是这么希望的！

## 第一条证据

现在我们手上已经有三个编译器二进制：

  1. `cwj`，由 Gnu C 编译器构建，
  2. `cwj0`，由 `cwj` 编译器构建，
  2. `cwj1`，由 `cwj0` 编译器构建

后面这两个本来应该完全一样，
但事实并非如此。
因此，
`cwj0`
没有生成正确的汇编输出，
而这又说明
编译器源码里还藏着某个缺陷。

那我们该怎样把问题范围缩小？
很简单，
我们手头已经有一整堆
放在 `tests/`
目录里的测试程序。
那就拿 `cwj`
和 `cwj0`
分别去跑这些测试，
看看它们会不会在某个用例上产生差异。

答案是：会，
而且差异出现在 `tests/input002.c`：

```
$ ./cwj -o z tests/input002.c ; ./z
17
$ ./cwj0 -o z tests/input002.c ; ./z
24
```

## 问题到底是什么

所以，
`cwj0`
确实生成了错误的汇编代码。
先来看测试源码：

```c
void main()
{
  int fred;
  int jim;
  fred= 5;
  jim= 12;
  printf("%d\n", fred + jim);
}
```

这里有两个局部变量：
`fred`
和 `jim`。
而两个编译器生成的汇编差异如下：

```
42c42
<       movl    %r10d, -4(%rbp)
---
>       movl    %r10d, -8(%rbp)
51c51
<       movslq  -4(%rbp), %r10
---
>       movslq  -8(%rbp), %r10
```

嗯，
第二个编译器把 `fred`
的偏移量算错了。
第一个编译器算出来的是正确的，
也就是相对于帧指针下方 `-4` 的位置。
第二个编译器却把它算成了 `-8`。

## 导致这个问题的原因

这些偏移量，
都是在 `cg.c`
的 `newlocaloffset()`
函数里算出来的：

```c
// Create the position of a new local variable.
static int localOffset;
static int newlocaloffset(int size) {
  // Decrement the offset by a minimum of 4 bytes
  // and allocate on the stack
  localOffset += (size > 4) ? size : 4;
  return (-localOffset);
}
```

每个函数开始时，
`localOffset`
都会被设成零。
之后每创建一个局部变量，
我们就取到它的大小，
传给 `newlocaloffset()`，
然后拿回对应的偏移量。

`fred`
和 `jim`
这两个局部变量都是 `int`，
大小都是 4。
所以它们的偏移量理应分别是 `-4`
和 `-8`。

## 再给我一点证据

于是我把 `newlocaloffset()`
单独抽到一个临时源文件 `z.c`
里
（`z.c` 一直是我常用的临时文件名），
然后单独编译它。
源码如下：

```c
static int localOffset=0;
static int newlocaloffset(int size) {
  localOffset += (size > 4) ? size : 4;
  return (-localOffset);
}
```

这是生成出来的汇编，
我顺手加了一些注释：

```
        .data
localOffset:
        .long   0
        
        .text
newlocaloffset:
        pushq   %rbp                     
        movq    %rsp, %rbp               # Set up the stack and
        movl    %edi, -4(%rbp)           # frame pointers
        addq    $-16,%rsp               
        movslq  localOffset(%rip), %r10  # Get localOffset into %r10
                                         # in preparation for the +=
        movslq  -4(%rbp), %r11           # Get size into %r11
        movq    $4, %r12                 # Get  4   into %r12
        cmpl    %r12d, %r11d             # Compare them
        jle     L2                       # Jump if size < 4
        movslq  -4(%rbp), %r11
        movq    %r11, %r10               # Get size into %r10
        jmp     L3                       # and jump to L3
L2:
        movq    $4, %r11                 # Otherwise get 4
        movq    %r11, %r10               # into %r10
L3:
        addq    %r10, %r10               # Add the += exression to the
                                         # cached copy of localOffset
        movl    %r10d, localOffset(%rip) # Save %r10 into localOffset
        movslq  localOffset(%rip), %r10
        negq    %r10                     # Negate localOffset
        movl    %r10d, %eax              # Set up the return value
        jmp     L1                      
L1:
        addq    $16,%rsp                 # Restore the stack and
        popq    %rbp                     # frame pointers
        ret                              # and return
```

嗯，
这段代码在尝试做
`localOffset += expression`。
而 `localOffset`
的副本已经被缓存进 `%r10`
里了。
但是，
这个表达式本身又把 `%r10`
拿去当工作寄存器用了，
于是缓存起来的 `localOffset`
就被自己覆盖掉了。

尤其是这一句：

```
        addq    %r10, %r10
```

明显就是错的：
这里本该拿两个不同的寄存器相加。

## 通过“作弊”来让三重测试（Triple Test）通过

如果我们把 `newlocaloffset()`
源码改写成下面这样：

```c
static int newlocaloffset(int size) {
  if (size > 4)
    localOffset= localOffset + size;
  else
    localOffset= localOffset + 4;
  return (-localOffset);
}
```

然后再执行：

```
$ make triple
cc -Wall -o cwj  cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
./cwj    -o cwj0 cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
./cwj0   -o cwj1 cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
size cwj[01]
   text    data     bss     dec     hex filename
 109652    3028      48  112728   1b858 cwj0
 109652    3028      48  112728   1b858 cwj1
```

那最后两个编译器二进制
就会 100% 完全一致。
但这其实只是把问题遮住了：
原本的 `newlocaloffset()`
源码按理说就应该能工作，
可它偏偏就是不对。

为什么我们明明知道 `%r10`
已经被占用，
却还会再次把它分配出去？

## 一个可能的嫌疑人

我又把之前加在 `cg.c`
里的那些 `printf()`
调试输出重新开了回来，
用来看寄存器在什么时候被分配、
又在什么时候被释放。
然后我注意到，
在下面这些汇编指令之后：

```
        movslq  -4(%rbp), %r11           # Get size into %r11
        movq    $4, %r12                 # Get  4   into %r12
        cmpl    %r12d, %r11d             # Compare them
        jle     L2                       # Jump if size < 4
```

所有寄存器都会被释放，
尽管 `%r10`
此时还保存着缓存下来的
`localOffset` 值。
那到底是哪一个函数
在生成这些代码，
并且把所有寄存器都释放掉了？
答案是：

```c
// Compare two registers and jump if false.
int cgcompare_and_jump(int ASTop, int r1, int r2, int label, int type) {
  int size = cgprimsize(type);

  // Check the range of the AST operation
  if (ASTop < A_EQ || ASTop > A_GE)
    fatal("Bad ASTop in cgcompare_and_set()");

  switch (size) {
  case 1:
    fprintf(Outfile, "\tcmpb\t%s, %s\n", breglist[r2], breglist[r1]);
    break;
  case 4:
    fprintf(Outfile, "\tcmpl\t%s, %s\n", dreglist[r2], dreglist[r1]);
    break;
  default:
    fprintf(Outfile, "\tcmpq\t%s, %s\n", reglist[r2], reglist[r1]);
  }
  fprintf(Outfile, "\t%s\tL%d\n", invcmplist[ASTop - A_EQ], label);
  freeall_registers(NOREG);
  return (NOREG);
}
```

从这段代码看，
我们当然可以释放 `r1`
和 `r2`，
所以我先试着把“释放全部寄存器”
改成只释放这两个。

是的，
这确实有帮助，
而且现有所有回归测试依然都能通过。
但还没完：
另外还有一个函数，
也在不恰当地释放所有寄存器。
看来是时候上 `gdb`
继续跟执行流程了。

## 真正的元凶

看起来真正的问题在于：
我忘了很多操作本身也可能只是更大表达式的一部分，
因此在表达式结果被使用或被丢弃之前，
我们不能贸然释放所有寄存器。

我在 `gdb`
里跟踪执行时发现，
处理三元运算符的那段代码
也会释放寄存器，
即便它此时可能还只是某个更大表达式的一部分，
而外层其实已经分配了别的寄存器
（位置在 `gen.c`）：

```c
static int gen_ternary(struct ASTnode *n) {
  ...
  // Generate the condition code
  genAST(n->left, Lfalse, NOLABEL, NOLABEL, n->op);
  genfreeregs(NOREG);           // HERE

  // Get a register to hold the result of the two expressions
  reg = alloc_register();

  // Generate the true expression and the false label.
  // Move the expression result into the known register.
  // Don't free the register holding the result, though!
  expreg = genAST(n->mid, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  genfreeregs(reg);             // HERE

  // Generate the false expression and the end label.
  // Move the expression result into the known register.
  // Don't free the register holding the result, though!
  expreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  genfreeregs(reg);             // HERE
  ...
}
```

翻了一遍 `cg.c`
之后，
我发现那里面的函数，
凡是寄存器真的不再需要了，
基本都会自己释放。
所以在生成条件代码后面紧跟的那次 `genfreeregs()`
其实完全可以删掉。

接着，
当我们把 true 表达式的结果
移动到那个专门为三元表达式结果预留的寄存器里之后，
就只需要释放 `expreg`
即可。
false 表达式那边也一样。

为了做到这一点，
我把 `cg.c`
里一个原本是 `static`
的函数改成了全局函数，
并顺手改了个名字：

```c
// Return a register to the list of available registers.
// Check to see if it's not already there.
void cgfreereg(int reg) { ... }
```

于是，
我们就可以把 `gen.c`
里处理三元运算符的代码
改写成这样：

```c
static int gen_ternary(struct ASTnode *n) {
  ...
    // Generate the condition code followed
  // by a jump to the false label.
  genAST(n->left, Lfalse, NOLABEL, NOLABEL, n->op);

  // Get a register to hold the result of the two expressions
  reg = alloc_register();

  // Generate the true expression and the false label.
  // Move the expression result into the known register.
  expreg = genAST(n->mid, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  cgfreereg(expreg);
  ...
  // Generate the false expression and the end label.
  // Move the expression result into the known register.
  expreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  cgfreereg(expreg);
  ...
}
```

加上这项修改之后，
编译器现在已经可以通过多项测试：

  + triple test：`$ make triple`
  + quadruple test，也就是再多做一轮编译器自编译：

```
$ make quad
...
./cwj  -o cwj0 cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
./cwj0 -o cwj1 cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
./cwj1 -o cwj2 cg.c decl.c expr.c gen.c main.c misc.c opt.c scan.c stmt.c sym.c tree.c types.c
size cwj[012]
   text    data     bss     dec     hex filename
 109636    3028      48  112712   1b848 cwj0
 109636    3028      48  112712   1b848 cwj1
 109636    3028      48  112712   1b848 cwj2
```

  + 用 Gnu C 编译出来的编译器跑回归测试：`$ make test`
  + 用“编译器自己编出来的自己”再跑回归测试：`$ make test0`
  
这感觉确实非常爽。

## 总结与下一步

我终于达成了这趟旅程最初的目标：
写出一个能够自编译的编译器。
总共花了 60 个部分、
5,700 行代码、
149 个回归测试，
以及 *Readme*
文件里 108,000 个单词。

当然，
这并不意味着旅程必须到此结束。
为了让这个编译器更接近生产可用，
其实还有大量工作可以做。
不过我也已经断断续续忙了大约两个月，
所以我觉得自己至少应该先休息一下。

在编译器编写之旅的下一部分中，
我会简单勾勒一下：
这个编译器接下来还可以做些什么。
也许其中一些事情会由我继续做；
也许会由你来做。 [下一步](../61_What_Next/Readme.md)
