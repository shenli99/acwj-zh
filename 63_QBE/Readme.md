# 第 63 部分：QBE 后端

我把上一版编译器停在了 2019 年底，
当时还计划着去实现一套更好的寄存器分配方案。
不过后来中间发生了不少事，
其中还包括 2020 年中一场个人层面的不幸事件，
所以这件事就被搁置了。

就在几周前
（也就是 2021 年 12 月中旬），
我遇到了一个叫
[QBE](https://c9x.me/compile/)
的项目，
作者是 Quentin Carbonneaux。
这个工具定义了一种中间语言，
非常适合作为我这种编译器的输出目标。
然后再由这套中间语言
继续下沉翻译成真正的汇编代码。
同时，
QBE 还提供并实现了：

 * 基于 SSA 的中间语言
 * 带 hint 的线性寄存器分配器
 * 复制消除（copy elimination）
 * 稀疏条件常量传播
 * 死指令消除
 * 小型栈槽寄存器化
 * 基于 SSA 形式拆分出来的 spill 与寄存器分配
 * 基于循环分析的智能 spill 启发式

本质上，
QBE 已经替一个编译器完成了很多
后端寄存器分配和代码优化工作。
既然 Quentin 已经把这些代码写好了，
我就决定干脆放弃现有的 x86-64 代码生成器，
改写成一个输出 QBE 中间语言的代码生成器。

结果就是当前这个版本的 `acwj` 编译器。
它依然能通过 triple test。
不过，
使用 QBE 后端生成的汇编代码，
尺寸大约只有第 62 版编译器输出的一半。

如果你想亲自试试这个版本的 `acwj`，
那你需要先下载并编译
[QBE](https://c9x.me/compile/)，
然后把 `qbe` 可执行文件装到你的 `$PATH`
里某个能找到的位置。
`acwj` 编译器会先把中间代码输出到一个以 `.q`
结尾的文件中，
然后调用 `qbe`
把它翻译成汇编，
再继续走正常的汇编与链接流程。

那么，
开始吧。

## QBE 中间语言

老实说，
我 *真正* 想做的，
其实是给你详细解释：
QBE 到底是怎样实现
[静态单赋值形式（static single assignment form）](https://en.wikipedia.org/wiki/Static_single_assignment_form)、
寄存器分配、
死代码消除等机制的。
但问题在于，
这些东西我自己现在也还没有完全吃透。
也许未来会有人去读 QBE 的源码，
然后像我之前讲解 `acwj`
那样把它系统说明清楚。

所以这一次，
我会退一步，
主要带你走一遍
QBE 所使用的中间语言长什么样，
以及我在新的代码生成器 `cg.c`
里是怎样把编译器对接到这门语言上的。

## 临时位置，而不是寄存器

QBE 中间语言是一种抽象语言，
并不是某个真实 CPU 的汇编语言。
因此，
它完全不必受限于“只有一组固定寄存器”之类的现实约束。

取而代之的，
是无限多个 *临时位置（temporary locations）*，
每个位置都有自己的名字。
全局可见的临时位置
以 `$` 开头；
而只在函数内部可见的临时位置
以 `%` 开头。

这些临时位置不需要事先声明，
可以在需要时动态创建。
但一旦创建，
每个临时位置都必须带有某种 *类型*。
这些类型
（以及它们的后缀字母）
包括：

 * 8 位字节（*b*）
 * 16 位半字（*h*）
 * 32 位字（*w*）
 * 64 位长字（*l*）

QBE 还支持
**s**ingle precision float、
**d**ouble precision float，
以及定义聚合类型的方法。
不过这些我在 `acwj`
里都没用到，
所以这里不展开。
如果你有兴趣，
可以去看
[QBE 中间语言参考文档](https://c9x.me/compile/doc/il.html)。

局部临时变量的创建方式，
和普通汇编里的操作其实很像。
例如：

```
  %b0 =w copy 5              # Create %b0 as a word temporary and
                             # initialise it with the value 5
  %fred =w add %c, %d        # Add two temporaries and store in the
                             # %fred word temporary
  %p =h call ntohs(h %foo)   # Call ntohs() with the value of the %foo
                             # temporary and save the halfword result
                             # in the %p temporary 
```

## 混合类型

每个临时位置都有类型。
这也就意味着，
不同类型之间的转换必须显式处理。
例如下面这样是不行的：

```
  %x =w copy 5               # int x = 5;
  %y =l copy %x              # long y = x;
```

当你需要把一个较小类型的值扩宽成更大类型时，
就必须先明确：
原来的小类型值到底是 *signed*
还是 *unsigned*。
例如：

```
  %x =w copy -5   # int x = -5;               32-bit value 0xfffffffb
  %y =l extsw %x  # long y = x;               0xfffffffffffffffb
  %z =l extuw %x  # long z = (unsigned) x;    0x00000000fffffffb
```

反过来，
把一个较宽的值存进较小的临时位置是允许的；
QBE 会直接截掉高位。

## 第一个例子

下面这段 C 程序：

```c
#include <stdio.h>

int main()
{
  int x= 5;
  long y= x;
  int z= (int)y;
  printf("%d %ld %d\n", x, y, z);
  return(0);
}
```

如果手工翻译成 QBE 中间语言，
可以写成：

```
data $L19 = { b "%d %ld %d\n" }
export function w $main() {
@L20
  %x =w copy 5
  %y =l extsw %x
  %z =w copy %y
  call $printf(l $L19, w %x, l %y, w %z)
  ret 0
}
```

这里有几件前面还没讲到的事。
字符串字面量 `"%d %ld %d\n"`
会被存成一串 **b**yte，
放在一个叫 `$L19`
的全局临时位置里。
严格来说，
`$L19`
表示的是这个字符串第一个字节的地址。

`main()`
被定义成一个非局部函数
（所以名字前面是 `$`），
返回一个 32 位 **w**ord。
`export`
关键字表示这个函数在当前文件外部也是可见的。

`@L20`
则是一个标签，
和普通汇编里的 label 没区别。
QBE 要求每个函数都必须有一个起始标签。

最后，
`ret`
负责从函数返回。
每个函数里只能有一个 `ret`，
它必须是函数的最后一行，
而且如果它带返回值，
这个值的类型还必须和函数声明的返回类型一致。

## `acwj` 生成的 QBE 输出

现在来看看，
`acwj`
会怎样把前面的那段 C 程序编译成 QBE 中间语言：

```
export function w $main() {
@L20
  %.t1 =w copy 5
  %x =w copy %.t1               # x = 5;
  %.t2 =w copy %x
  %.t3 =l extsw %.t2
  %y =l copy %.t3               # y = x;
  %.t4 =l copy %y
  %.t5 =w copy %.t4
  %z =w copy %.t5               # z = (int) y;
  %.t6 =w copy %z
  %.t7 =l copy %y               # Put the arguments into "registers"
  %.t8 =w copy %x
  %.t9 =l copy $L19             # Call pritnf(), get result back
  %.t10 =w call $printf(l %.t9, w %.t8, l %.t7, w %.t6, )
  %.t11 =w copy 0
  %.ret =w copy %.t11           # Set the return value to 0
  jmp @L18
@L18
  ret %.ret
}
```

很不优雅，
对吧？
`acwj`
仍然执着地认为像 `x`、`y`
这样的变量是“住在内存里”的，
而“寄存器”
只是用来在这些变量之间搬运数据的。
我把临时名字写成以 `.t`
开头，
这样就不会和真正的 C 变量名冲突。

这里的 `return(0)`
被翻译成：
先把值复制到 `%.ret`
这个临时位置里，
再跳到函数最后一行。
显然，
在这个例子里，
这次跳转完全是多余的。

所以总体上，
`acwj`
自己吐出来的中间代码其实并不高效。
这也正是我之前一直想给 `acwj`
加入优化机制的原因。
不过现在好的一面是：
QBE 在死代码消除和代码优化上做得相当不错。
它把上面的中间代码翻译成 x86-64 汇编后，
结果会是这样：

```asm
.text
.globl main
main:
        pushq %rbp
        movq %rsp, %rbp                 # Set up the frame & stack pointers
        movl $5, %ecx                   # Copy 5 into three arguments
        movl $5, %edx
        movl $5, %esi
        leaq L19(%rip), %rdi            # Load the address of the string
        callq printf                    # Call printf()
        movl $0, %eax                   # Set the main() return value
        leave
        ret                             # and return from main()
```

很漂亮。
所有东西都放在寄存器里，
局部变量完全没有落到栈上。

## 带地址的局部变量

QBE 很擅长让尽可能多的数据留在寄存器里。
但总有一些场景是做不到的。
例如，
当我们需要拿到某个变量的地址时，
像这样：

```c
int main()
{
  int x= 5;
  int *p = &x;
  printf("%d %lx\n", x, (long)p);
  return(0);
}
```

这里的变量 `x`
显然必须真的存到内存里，
这样我们才能取到它的地址并赋给 `p`。
为此，
我们需要使用 QBE 那些用于分配和访问内存的操作：

```
export function w $main() {
@L20
  %x =l alloc8 1                # Allocate 8 bytes for x
  %.t1 =w copy 5
  storew %.t1, %x               # Store 5 as a 32-bit value in x
  %.t2 =l copy %x               # Get the address of x
  %p =l copy %.t2
  %.t3 =l copy %p
  %.t5 =w loadsw %x             # Get the 32-bit value at x
  %.t6 =l copy $L19
  %.t7 =w call $printf(l %.t6, w %.t5, l %.t3)
  %.t8 =w copy 0
  %.ret =w copy %.t8
  jmp @L18
@L18
  ret %.ret
}
```

现在 `%x`
会被视为“指向栈上 8 字节空间的指针”。
我选择按 8 字节一组来分配，
这样能保证 8 字节的 long
和指针都得到正确对齐。
这时我们就需要用 `store`
和 `load`
操作，
来读写 `%x`
所指向的那块内存。

上面的中间代码再交给 QBE，
会被翻译成：

```
main:
        pushq %rbp
        movq %rsp, %rbp
        subq $16, %rsp                  # Make space on the stack
        movl $5, -8(%rbp)               # Store 5 on the stack as x
        leaq -8(%rbp), %rdx             # Get the address of x
        movl $5, %esi                   # Optimisation: use literal 5
        leaq L19(%rip), %rdi            # instead of accessing the stack
        callq printf
        movl $0, %eax
        leave
        ret
```

这已经是对 `acwj`
那段中间语言非常理想的一次翻译了。

## QBE 和 `char`

QBE 并不会把 8 位 byte
或 16 位 halfword
当成主要类型：
它并没有 byte
或 halfword
级别的临时位置。
因此，
这些值必须存放在栈上或堆上。
所以，
`acwj`
会把下面这段 C 代码：

```c
int main()
{
  char x= 65;
  printf("%c\n", x);
  return(0);
}
```

编译成：

```
export function w $main() {
@L20
  %x =l alloc4 1                        # Allocate 4 bytes on the stack
  %.t1 =w copy 65
  storew %.t1, %x                       # Store 65 as a 16-bit word
  %.t2 =w loadub %x                     # Reload it as an 8-bit unsigned byte
  ...
}
```

# 比较和条件跳转

QBE 提供了一组指令，
用来比较两个临时位置，
并在比较结果为真时把第三个临时位置设成 1，
否则设成 0。
这些指令包括：

 * `ceq` 表示相等
 * `cne` 表示不等
 * `csle` 表示有符号小于等于
 * `cslt` 表示有符号小于
 * `csge` 表示有符号大于等于
 * `csgt` 表示有符号大于
 * `cule` 表示无符号小于等于
 * `cult` 表示无符号小于
 * `cuge` 表示无符号大于等于
 * `cugt` 表示无符号大于

然后再跟上两个参数的类型字母。
因此，
下面这段 C 代码：

```c
  int x= 5;
  int y= 6;
  int z= x>y;
```

就可以编译成：

```
  %x =w copy 5
  %y =w copy 6
  %z =w csgtw %x, %y
```

QBE 只有一种条件跳转指令：`jnz`。
当给定的临时位置非零时，
`jnz`
跳到第一个标签；
否则跳到第二个标签。
因此 `jnz`
必须总是带两个标签。

利用这一点，
我们可以把下面的 C 代码：

```c
  if (5>6)
    z= 100;
  else
    z= 200;
```

翻译成：

```
@L19
  %.t1 =w csgtw 5, 6            # Compare 5>6, store result in %.t1
  jnz %.t1, @Ltrue, @Lfalse     # Jump to @Ltrue if true, @Lfalse otherwise
@Ltrue
  %z =w copy 100                # Set z to 100 and skip using the
  jmp @L18                      # absolute jump instruction, jmp
@Lfalse
  %z =w copy 200                # Set z to 200
@L18
  ...
```

借助这些比较指令和 `jnz`，
我们就可以实现 IF、FOR
和 WHILE
这类控制结构。

## Struct 和数组

这一块相对直接。
访问 struct 字段时，
只要先取到基地址，
再加上该字段的偏移量即可。
访问数组元素时，
则需要先按单个元素大小
对下标做缩放。
例如这段 C 代码：

```c
struct foo {
    int field1;
    int field2;
} x;

int main() {
  x.field2= 45;
  return(0);
}
```

会被 `acwj`
编译成：

```
export data $x = align 8 { l 0 }
export function w $main() {
@L19
  %.t1 =w copy 45
  %.t2 =l copy $x               # Get the base address of x
  %.t3 =l copy 4                
  %.t2 =l add %.t2, %.t3        # Add 4 to it
  storew %.t1, %.t2             # Store 45 at this address
  ...
}
```

## 旧版和 QBE 版代码尺寸对比

对编译器作者来说，
QBE 比底层真实机器汇编
是一个更容易瞄准的目标。
同时，
QBE 还会进一步优化
从中间语言生成出来的汇编代码。
并且，
QBE 至少支持两个机器目标：
x86-64
和 ARM-64，
这也让前端编译器天然具备了一定可移植性。

我们可以分别用旧版和新版 `acwj`
去编译编译器自身的每个 C 文件，
然后比较两者最终生成的目标代码大小：

```
Version 62   QBE      File
-----------------------------
  18079     6961      cg.o
  14200     7440      decl.o
  11735     4815      expr.o
  10063     4349      gen.o
   4965     2571      main.o
   1492      522      misc.o
   1248      424      opt.o
   9466     4495      scan.o
   6531     2888      stmt.o
   7770     3611      sym.o
   3617     1711      tree.o
   2473     1777      types.o
 106964    44257      Self-compiled cwj binary
```

## 总结

我其实很庆幸，
自己当初写 `acwj`
时是直接面向真实机器来做的，
因为这逼着我必须处理
寄存器分配、
函数参数传递、
数据对齐
之类的问题。
但另一方面，
`acwj`
原先生成出来的汇编质量确实很一般。

而现在，
我也很庆幸自己找到了这样一条路：
通过使用
[QBE 中间语言](https://c9x.me/compile/doc/il.html)，
让编译器前端也能产出高质量的汇编输出。

## 下一步

我也不确定这之后还有没有“下一步”。
编译器现在已经通过了所有测试，
能编译自己，
而且生成出来的代码质量也已经相当不错了。

不过我确实很想继续学习
QBE 背后体现出来的那些概念，
比如 SSA、
寄存器分配等等。
所以也许接下来，
我会去做一些研究，
然后把这些内容再写成新的说明。

[下一步](../64_6809_Target/Readme.md)
