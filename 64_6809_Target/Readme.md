# 第 64 部分：在 8 位 CPU 上自编译

我又回来了，
继续这一章编译器编写之旅。
这一次，
目标是让编译器在一颗来自 1980 年代的 8 位 CPU 上完成自编译。
这是一项既有趣、
有时也挺折磨人的工作。
下面我会总结自己为此做过的事情。

在 CPU 选择上，
我挑了
[Motorola 6809](https://en.wikipedia.org/wiki/Motorola_6809)。
它大概算是 1980 年代功能最强的一批 8 位 CPU 之一，
拥有不少很好用的寻址模式，
更重要的是，
它还有一个相当实用的栈指针。

给 6809 写编译器最难的地方，
在于地址空间限制。
像很多 8 位 CPU 一样，
它总共只有 64K 内存
（没错，就是 65,536 个 _byte_！），
而在大多数老式 6809 系统里，
其中相当一部分还会被 ROM 占掉。

我会往这个方向走，
是因为到了 2023 年，
我想尝试自己做一台以 6809 为 CPU 的
单板计算机（SBC）。
更具体地说，
我想要一台至少有半兆内存、
有类似磁盘的存储设备、
还能跑类 Unix 操作系统的机器。

最终的结果就是
[MMU09 SBC](https://github.com/DoctorWkt/MMU09)。
这个项目目前还没彻底做完；
它已经有类 Unix 系统了，
也支持多任务，
但还没有抢占式多任务。
每个进程大约能拿到 63.5K
可用地址空间
（也就是 RAM）。

在做 MMU09 的过程中，
我需要找一套合适的 C 编译器，
来编译操作系统、
库
以及各种应用程序。
我最初用的是
[CMOC](http://perso.b2b2c.ca/~sarrazip/dev/cmoc.html)，
但后来改成了
[vbcc](http://www.compilers.de/vbcc.html)。
中途我还发现了 Alan Cox 的
[Fuzix Compiler Kit](https://github.com/EtchedPixels/Fuzix-Compiler-Kit)，
它是一套仍在开发中的 C 编译器，
面向许多 8 位和 16 位 CPU。

这一切最终让我开始思考：
有没有可能让 C 编译器直接运行在 6809 *本机* 上，
而不仅仅是在更强的系统上做交叉编译？
我原本觉得 Fuzix Compiler Kit
也许有机会胜任，
但结果不行，
它实在太大了，
根本塞不进 6809 自身。

于是问题，
或者说目标，
就变成了：
能不能把 “acwj” 编译器改造成
适合在 6809 平台上运行？

## 6809 这颗 CPU

先从编译器作者的视角，
看一眼 6809。
前面已经提过 64K 地址空间限制了：
这会逼着 “acwj” 编译器必须做大幅重构，
才能真正塞进去。
现在先看它的体系结构。

![](docs/6809_Internal_Registers.png)

Creative Commons CC0 license，
[Wikipedia](https://commons.wikimedia.org/wiki/File:6809_Internal_Registers.svg)

对于一颗 8 位 CPU 来说，
6809 的寄存器其实不少。
当然，
它不像 x64
或者某些 RISC CPU
那样有一大堆通用寄存器。
它的核心是一个 16 位的 `D` 寄存器，
逻辑运算和算术运算基本都围绕它展开。
同时，
`D`
还可以拆成两个 8 位寄存器 `A` 和 `B`，
其中 `B`
是 `D`
的低字节。

在做逻辑和算术运算时，
第二个操作数要么来自通过某种寻址模式访问到的内存，
要么来自一个字面量。
运算结果总是回写到 `D`
里，
也就是说它天然是一个
_accumulator_（累加器）式架构。

至于访问内存，
6809 提供了相当多的寻址模式，
其实多到比编译器真正需要的还要多。
例如有索引寄存器 `X` 和 `Y`，
可以拿来访问数组元素：
如果你知道数组基地址，
而 `X`
里存着元素下标，
那就很好用。
我们也可以用一个有符号常量
加上栈指针 `S`
来访问内存；
这使得 `S`
基本上可以被当作
[帧指针（frame pointer）](https://en.wikipedia.org/wiki/Call_stack#FRAME-POINTER)
来用。
函数的局部变量可以放在帧指针之下，
而函数参数则放在帧指针之上。

看几个例子会更直观一些：

```
    ldd #2         # Load D with the constant 2
    ldd 2          # Load D from addresses 2 and 3 (16 bits)
    ldd _x         # Load D from the location known as _x
    ldd 2,s        # Load D from an argument on the stack
    std -20,s      # Store D to a local variable on the stack
    leax 8,s       # Get the (effective) address which is S+8
                   # and store it in the X register
    ldd 4,x        # Now use that as a pointer to an int array
                   # and load the value at index 2 - remember
                   # that D is 16-bits (2 bytes), so 4 bytes
                   # are two 16-bit "words"
    addd -6,s      # Add the int we just fetched to a local
                   # variable and save it in the D register
```

如果想看更细节的内容，
我建议你直接翻一下
[6809 数据手册](docs/6809Data.pdf)。
第 5 到 6 页讲寄存器，
第 16 到 18 页讲寻址模式，
第 25 到 27 页列出了可用指令。

回到让 “acwj” 面向 6809 这件事上。
多种寻址模式当然很好。
我们可以直接处理 8 位和 16 位值，
但它没有 32 位寄存器。
好吧，
这个还算能想办法解决。

真正更大的问题，
除了 64K 地址空间之外，
是 “acwj” 编译器原本是按那种拥有两操作数、
三操作数指令，
而且寄存器还很多的架构来写的。
比如：

```
   load R1, _x		# Bring _x and _y into registers
   load R2, _y
   add  R3, R1, R2	# R3= R1 + R2
   save R3, _z		# Store the result into _z
```

而 6809 通常只有 `D`
寄存器作为其中一个显式操作数，
另一个操作数来自内存或字面量，
结果永远落回 `D`
本身。

## 保留 QBE 后端

我还想把现有的 QBE 后端继续保留下来。
因为我知道：
当我修改编译器时，
这个后端会非常有价值。
我可以让测试同时跑在 QBE
和 6809 两个后端上，
然后对比结果。
而且，
我也始终可以用 QBE 后端继续跑 triple test，
拿它来给编译器做压力测试。

所以现在完整的目标其实是：
我能不能拿编译器解析器生成出来的抽象语法树（AST），
分别生成两种完全不同架构的代码：
QBE
（更像 RISC，三操作数指令）
和 6809
（本质上只有一个寄存器，两操作数且源/目标常常是隐含的）？
并且，
还能让编译器在这两种架构上都实现自编译？

这会是一趟很有意思的旅程。

## 代码生成器契约

既然现在要有两个不同后端，
那我们就需要在
架构无关的代码生成部分
（[gen.c](gen.c)）
和各个架构相关后端之间，
定义一个“契约”，
或者说 API。
这个接口现在定义在 [gen.h](gen.h)
里。

基础 API 和以前差不多：
我们传入一个或多个“寄存器编号”，
再拿回一个持有结果值的寄存器编号。
不过这次有个变化：
很多函数现在还会额外接收操作数的
架构无关 `type`。
这些类型定义在 [defs.h](defs.h)
里：

```
// Primitive types. The bottom 4 bits is an integer
// value that represents the level of indirection,
// e.g. 0= no pointer, 1= pointer, 2= pointer pointer etc.
enum {
  P_NONE, P_VOID = 16, P_CHAR = 32, P_INT = 48, P_LONG = 64,
  P_STRUCT=80, P_UNION=96
};
```

如果你去看 QBE 代码生成器
[cgqbe.c](cgqbe.c)，
会发现它和上一章 “acwj” 旅程里的版本差别并不大。
有件事需要注意：
我把其中一些函数抽取到了单独的
[targqbe.c](targqbe.c)
里，
因为现在解析器和代码生成器
已经不再是同一个程序了。

接下来我们看 6809 代码生成器。

## 6809 专用类型和 D 寄存器

真正的大问题是：
在 6809 上，
我们到底怎样保留“多个寄存器”这种抽象？
这个问题我下一节再讲，
不过前面需要先绕一小段。

每个架构相关代码生成器，
拿到的都是通用类型：
`P_CHAR`、`P_INT`
等等。
对于 6809 后端来说，
我们会先把它们转换成 6809 自己的类型系统，
定义在 [cg6809.c](cg6809.c)
里：

```
#define PR_CHAR         1	// size 1 byte
#define PR_INT          2	// size 2 bytes
#define PR_POINTER      3	// size 2 bytes
#define PR_LONG         4	// size 4 bytes
```

于是你会在这个文件里经常看到类似这样的代码：

```
  int primtype= cgprimtype(type);

  switch(primtype) {
    case PR_CHAR:
      // Code to generate char operations
    case PR_INT:
    case PR_POINTER:
      // Code to generate int operations
    case PR_LONG:
      // Code to generate long operations
  }
```

虽然 `PR_INT`
和 `PR_POINTER`
大小相同，
而且生成出来的代码也一样，
我还是故意把它们区分开了。
原因是：
指针本质上应该看作无符号值，
而 `int`
则是有符号值。
以后如果我真要给编译器加入 signed/unsigned
类型，
那 6809 后端这一层至少已经先铺好路了。

## 当没有寄存器时，寄存器怎么办

现在回到核心问题：
如果代码生成器 API
是建立在“寄存器编号”之上的，
那在只有一个累加器 `D`
的 6809 上，
我们到底怎么写后端？

我刚开始写 6809 后端时，
最直接的做法是：
搞一组 4 字节的内存位置，
名字就叫 `R0`、`R1`、`R2`
等等。
你现在还能在
[lib/6809/crt0.s](lib/6809/crt0.s)
里看到它们：

```
R0:     .word   0
        .word   0
R1:     .word   0
        .word   0
...
```

这套办法确实让我把 6809 后端先跑起来了，
但生成出来的代码糟透了。
比如这段 C 代码：

```
  int x, y, z;
  ...
  z= x + y;
```

会被翻译成：

```
  ldd  _x
  std  R0
  ldd  _y
  std  R1
  ldd  R0
  addd R1
  std  R2
  ldd  R2
  std  _z
```

后来我意识到：
6809 是一颗非常“面向地址”的 CPU。
它有很多寻址模式，
而大多数指令的操作数本质上也是“一个地址”
或者“一个字面量”。
所以，
与其坚持“寄存器列表”，
不如改成维护一份“位置（locations）”列表。

一个位置可以是下面这些类型之一，
定义在 [cg6809.c](cg6809.c)
里：

```
enum {
  L_FREE,               // This location is not used
  L_SYMBOL,             // A global symbol with an optional offset
  L_LOCAL,              // A local variable or parameter
  L_CONST,              // An integer literal value
  L_LABEL,              // A label
  L_SYMADDR,            // The address of a symbol, local or parameter
  L_TEMP,               // A temporarily-stored value: R0, R1, R2 ...
  L_DREG                // The D location, i.e. B, D or Y/D
};
```

然后我们维护一张“空闲/在用位置表”，
每个元素结构如下：

```
struct Location {
  int type;             // One of the L_ values
  char *name;           // A symbol's name
  long intval;          // Offset, const value, label-id etc.
  int primtype;         // 6809 primitive type
};
```

举几个例子：

 - 一个全局 `int x`
   会被表示成 `L_SYMBOL`，
   `name`
   是 `"x"`，
   `primtype`
   是 `PR_INT`。
 - 一个局部 `char *ptr`
   会被表示成 `L_LOCAL`，
   没有名字，
   但 `intval`
   会记录它在栈帧中的偏移，
   比如 `-8`。
   `primtype`
   则是 `PR_POINTER`。
   如果它是函数参数，
   偏移量就会是正数。
 - 如果操作数是 `&x`
   这种“取地址”表达式，
   那位置就会是 `L_SYMADDR`，
   `name`
   为 `"x"`。
 - 一个像 456 这样的字面量值，
   会是 `L_CONST`，
   `intval`
   为 456，
   `primtype`
   为 `PR_INT`。
 - 如果操作数当前已经在 `D`
   寄存器里，
   那它就是一个 `L_DREG`
   位置，
   并带有相应的 `PR_`
   类型。

也就是说，
“位置”
在这里其实扮演了“寄存器”的角色。
我们总共准备了 16 个位置：

```
#define NUMFREELOCNS 16
static struct Location Locn[NUMFREELOCNS];
```

来看看 6809 上生成加法的代码：

```
// Add two locations together and return
// the number of the location with the result
int cgadd(int l1, int l2, int type) {
  int primtype= cgprimtype(type);

  load_d(l1);

  switch(primtype) {
    case PR_CHAR:
      fprintf(Outfile, "\taddb "); printlocation(l2, 0, 'b'); break;
    case PR_INT:
    case PR_POINTER:
      fprintf(Outfile, "\taddd "); printlocation(l2, 0, 'd'); break;
      break;
    case PR_LONG:
      fprintf(Outfile, "\taddd "); printlocation(l2, 2, 'd');
      fprintf(Outfile, "\texg y,d\n");
      fprintf(Outfile, "\tadcb "); printlocation(l2, 1, 'f');
      fprintf(Outfile, "\tadca "); printlocation(l2, 0, 'e');
      fprintf(Outfile, "\texg y,d\n");
  }
  cgfreelocn(l2);
  Locn[l1].type= L_DREG;
  d_holds= l1;
  return(l1);
}
```

我们先根据通用类型，
推导出 6809 对应的专用类型。
然后把第一个位置 `l1`
的值加载进 `D`
寄存器。
接着，
根据 6809 类型的不同，
输出不同的指令，
并在每条指令后把第二个位置 `l2`
打印出来作为操作数。

加法完成后，
我们释放第二个位置，
并把第一个位置 `l1`
标记为 `L_DREG`，
表示它现在已经住进 `D`
寄存器里了。
同时也记下 `D`
当前正被占用，
然后返回。

借助“位置”这个抽象，
C 代码 `z= x + y`
现在就会被翻译成：

```
  ldd  _x	; i.e. load_x(l1);
  addd _y	; i.e. fprintf(Outfile, "\taddd "); printlocation(l2, 2, 'd');
  std  _z	; performed in another function, cgstorglob()
```

## 处理 `long`

6809 只有 8 位和 16 位运算，
但编译器需要合成 32 位 `long`
运算。
同时，
它也没有 32 位寄存器。

> 题外话：6809 是大端序。
> 如果某个 `long` 值 `0x12345678`
> 存在名为 `foo`
> 的 `long`
> 变量中，
> 那么 `foo+0`
> 处是 `0x12`，
> `foo+1`
> 处是 `0x34`，
> `foo+2`
> 处是 `0x56`，
> `foo+3`
> 处是 `0x78`。

这里我借用了 Alan Cox 在
[Fuzix Compiler Kit](https://github.com/EtchedPixels/Fuzix-Compiler-Kit)
里的思路。
我们用 `Y`
寄存器保存 32 位 `long`
的高半部分，
而 `D`
寄存器保存低半部分：

![](docs/long_regs.png)

6809 原本就把 `D`
寄存器的低半部分称为 `B`，
用于 8 位操作；
而 `A`
则是 `D`
的高半部分。

看看前面 `cgadd()`
里处理 `long`
的分支，
如果 `x`、`y` 和 `z`
都是 `long`
而不是 `int`，
那它会生成：

```
  ldd  _x+2	; Get lower half of _x into D
  ldy  _x+0	; Get upper half of _x into Y
  addd _y+2	; Add lower half of _y to D
  exg  y,d	; Swap Y and D registers
  adcb _y+1	; Add _y offset 1 to the B register with carry
  adca _y+0	; Add _y offset 0 to the A register with carry
  exg  y,d	; Swap Y and D registers back again
  std  _z+2	; Finally store D (the lower half) in _z offset 2
  sty  _z	; and Y (the upper half) in _z offset 0
```

这确实有点麻烦：
6809 有 16 位 `addd`，
但它没有带进位的 16 位加法。
所以我们只能退回去，
用两次 8 位带进位加法，
拼出同样的结果。

也正是这种“指令集能力不整齐”的现实，
让 [cg6809.c](cg6809.c)
里的很多代码看起来都不太优雅。

# `printlocation()`

位置系统里，
很多活都是由 `printlocation()`
完成的。
我们分几段来看。

```
// Print a location out. For memory locations
// use the offset. For constants, use the
// register letter to determine which part to use.
static void printlocation(int l, int offset, char rletter) {
  int intval;

  if (Locn[l].type == L_FREE)
    fatald("Error trying to print location", l);

  switch(Locn[l].type) {
    case L_SYMBOL: fprintf(Outfile, "_%s+%d\n", Locn[l].name, offset); break;
    case L_LOCAL: fprintf(Outfile, "%ld,s\n",
                Locn[l].intval + offset + sp_adjust);
        break;
    case L_LABEL: fprintf(Outfile, "#L%ld\n", Locn[l].intval); break;
    case L_SYMADDR: fprintf(Outfile, "#_%s\n", Locn[l].name); break;
    case L_TEMP: fprintf(Outfile, "R%ld+%d\n", Locn[l].intval, offset);
        break;
    ...
```

如果位置是 `L_FREE`，
那当然没意义再去打印它。

对于符号，
我们输出符号名和偏移量。
这样一来，
对于 `int`
和 `long`，
就能访问组成它们的 2 个或 4 个字节：
比如 `_x+0`、`_x+1`、`_x+2`、`_x+3`。

对于局部变量和函数参数，
我们输出它在栈帧中的位置
（也就是 `intval`
加上偏移）。
如果局部 `long`
变量 `fred`
位于栈上 `-12`
的位置，
那我们就可以通过 `-12,s`、
`-11,s`、
`-10,s`、
`-9,s`
访问到它的全部四个字节。

没错，
这里出现了一个叫 `sp_adjust`
的东西。
我马上就会说到它。

至于 `L_TEMP`。
和之前所有版本的编译器一样，
有些时候我们必须把中间结果暂存到某个地方，
比如：

```
  int z= (a + b) * (c - d) / (e + f) * (g + h - i) * (q - 3);
```

这里括号里一共有五个中间结果，
必须先保存起来，
才能继续做乘除运算。
而最早那套假寄存器 `R0`、`R1`、`R2`
这时就又有用了！
当我需要一个地方保存中间结果时，
就分配一个这样的 `L_TEMP`
位置，
然后把值存进去。
在 [cg6809.c](cg6809.c)
中有 `cgalloctemp()`
和 `cgfreealltemps()`
两个函数负责这件事。

# `printlocation()` 和字面量

对于大多数位置，
我们只要直接打印出它的名字，
或者它在栈上的位置，
再加上偏移量就可以了。
代码生成器前面已经把要执行的指令打印出来了，
因此例如：

```
  ldb _x+0	; Will load one byte from _x into B
  ldd _x+0	; Will load two bytes from _x into D
```

但如果是字面量值，
比如 `0x12345678`，
那该怎么打印？
末尾只打印 `0x78`
吗？
还是要打印 `0x5678`？
又或者像加法那样，
我们需要分别访问 `0x34`
和 `0x12`？

这就是 `printlocation()`
为什么还需要 `rletter`
参数：

```
static void printlocation(int l, int offset, char rletter);
```

在处理字面量时，
我们用这个参数来决定
到底输出哪一部分、
以及输出多宽。
我选用的这些字母大多对应 6809 的寄存器名，
也有少数是我自己补出来的。
以字面量 `0x12345678`
为例：

 - `'b'` 输出 `0x78`
 - `'a'` 输出 `0x56`
 - `'d'` 输出 `0x5678`
 - `'y'` 输出 `0x1234`
 - `'f'` 输出 `0x34`
 - `'e'` 输出 `0x12`

## 辅助函数

编译器有一些必须做的操作，
而 6809 本身并没有对应指令：
例如乘法、
除法、
多位移位等等。

为了解决这个问题，
我借用了
[Fuzix Compiler Kit](https://github.com/EtchedPixels/Fuzix-Compiler-Kit)
里的若干辅助函数。
它们都放在归档库
`lib/6809/lib6809.a`
里。
[cg6809.c](cg6809.c)
中的 `cgbinhelper()`
函数：

```
// Run a helper subroutine on two locations
// and return the number of the location with the result
static int cgbinhelper(int l1, int l2, int type,
                                char *cop, char *iop, char *lop);
```

会先把位置 `l1`
和 `l2`
的值取出来压栈，
然后根据类型，
去调用 `cop`、`iop`
和 `lop`
里给出的对应 char/int/long
辅助函数。
因此，
代码生成器里处理乘法的函数，
就可以简单写成：

```
// Multiply two locations together and return
// the number of the location with the result
int cgmul(int r1, int r2, int type) {
  return(cgbinhelper(r1, r2, type, "__mul", "__mul", "__mull"));
}
```

# 跟踪局部变量和参数的位置

函数的局部变量和参数都存放在栈上，
我们通过“相对于栈指针的偏移量”访问它们，
例如：

```
  ldd -12,s     ; Load the local integer variable which is 12 bytes
                ; below the stack pointer
```

但这里有个问题：
如果栈指针自己动了怎么办？
看这段代码：

```
int main() {
 int x;
 
 x= 2; printf("%d %d %d\n", x, x, x);
 return(0);
}

```

假设 `x`
最初位于相对于栈指针偏移 0 的位置。
可当我们调用 `printf()`
时，
会把 `x`
的多个副本压栈作为参数。
这时真正的 `x`
就不再在 0，
而是跑到了 2、
4
等等位置。
因此我们实际上必须生成这样的代码：

```
  ldd 0,s	; Get x's value
  pshs d	; Push it on the stack
  ldd 2,s	; Get x's value, note new offset
  pshs d	; Push it on the stack
  ldd 4,s	; Get x's value, note new offset
  pshs d	; Push it on the stack
  ldd #L2	; Get the address of the string "%d %d %d\n"
  pshs d	; Push it on the stack
  lbsr _printf	; Call printf()
  leas 8,s	; Pull the 8 bytes of arguments off the stack
```

那我们到底怎么跟踪
“当前局部变量和参数的真实偏移”？
答案是 [cg6809.c](cg6809.c)
里的 `sp_adjust`
变量。
每次我们往栈上压入东西，
就把压入的字节数加到 `sp_adjust`
里；
每次出栈，
或者通过移动栈指针把栈往上收回去，
就把对应字节数减掉。
例如：

```
// Push a location on the stack
static void pushlocn(int l) {
  load_d(l);

  switch(Locn[l].primtype) {
    ...
    case PR_INT:
      fprintf(Outfile, "\tpshs d\n");
      sp_adjust += 2;
      break;
    ...
  }
  ...
}
```

而在 `printlocation()`
里打印局部变量和参数时：

```
    case L_LOCAL: fprintf(Outfile, "%ld,s\n",
                Locn[l].intval + offset + sp_adjust);
```

另外，
在生成某个函数汇编的末尾，
还有一点额外检查：

```
// Print out a function postamble
void cgfuncpostamble(struct symtable *sym) {
  ...
  if (sp_adjust !=0 ) {
    fprintf(Outfile, "; DANGER sp_adjust is %d not 0\n", sp_adjust);
    fatald("sp_adjust is not zero", sp_adjust);
  }
}
```

关于 6809 汇编代码生成，
我大致就讲到这里。
没错，
[cg6809.c](cg6809.c)
必须处理 6809 指令集的各种古怪之处，
这也是它会比 [cgqbe.c](cgqbe.c)
大得多的原因。
不过我 *希望* 自己已经在 [cg6809.c](cg6809.c)
里写了足够多的注释，
让你能跟着看懂它到底在做什么。

其中确实还有几件比较棘手的小事，
比如跟踪 `D`
寄存器现在是空闲还是在用，
以及 `long`
相关那一整套合成运算我也不敢说完全没有遗漏。

接下来我们得进入一个更大的话题：
6809 那个 64K 地址空间限制。

## 怎样把编译器塞进 65,536 字节

最初的 “acwj” 编译器是一个单体可执行文件。
它读取 C 预处理器的输出，
完成扫描、
解析
和代码生成，
最后直接输出汇编。
它会把符号表、
每个函数的 AST 树
都放在内存里，
而且一旦某个数据结构创建出来，
基本从不考虑释放。

这一整套做法，
显然不可能让编译器塞进 64K 内存！
所以在 6809 自编译这件事上，
我的办法是：

1. 把编译器拆成多个阶段，
   每个阶段只做整个编译任务中的一小部分，
   阶段之间通过中间文件通信。
2. 尽量少地把符号表和 AST 树留在内存中。
   它们更多地放到文件里，
   需要时再读写。
3. 尽可能使用 `free()`
   对不用的数据结构做垃圾回收。

下面分别来看。

## 编译器的七个阶段

现在编译器被拆成七个阶段，
每个阶段都有自己的可执行程序：

1. 外部 C 预处理器负责解释 `#include`、`#ifdef`
   和预处理器宏。
2. 词法分析器读取预处理器输出，
   产生 token 流。
3. 解析器读取 token 流，
   构建符号表和 AST 树集合。
4. 代码生成器利用 AST 树和符号表生成汇编代码。
5. 外部 peephole 优化器改进汇编输出。
6. 外部汇编器生成目标文件。
7. 外部链接器把 `crt0.o`、各目标文件
   以及若干库链接成最终可执行文件。

现在我们有一个前端程序 [wcc.c](wcc.c)
来协调整个流程。
词法分析器是 `cscan`。
解析器是 `cparse6809`
或 `cparseqbe`。
代码生成器是 `cgen6809`
或 `cgenqbe`。
peephole 优化器是 `cpeep`。
这些程序在执行 `make install`
后都会安装到 `/opt/wcc/bin`
下。

代码生成器分成两个版本很容易理解，
但为什么解析器也要两个？
原因是：
不同架构下，
`sizeof(int)`、
`sizeof(long)`
之类的值并不相同，
解析器在做类型处理时也必须知道这些信息。
因此才有了
[targ6809.c](targ6809.c)
和 [targqbe.c](targqbe.c)
这两个文件，
它们会分别被编译进解析器和代码生成器中。

> 顺带一提：6809 后端有自己的 peephole 优化器。
> 而 QBE 后端则借助 `qbe`
> 程序把 QBE 代码转成 x64 代码。
> 这也算是一种优化吧 :-)

## 中间文件

在这七个阶段之间，
我们需要中间文件来承接上一个阶段的输出。
通常这些中间文件会在编译结束后被删掉；
如果你用 `wcc`
的 `-X`
命令行参数，
就可以保留它们。

C 预处理器的输出会放到一个以 `_cpp`
结尾的临时文件里，
例如如果正在编译 `fred.c`，
那中间文件名可能是 `foo.c_cpp`。

tokeniser 的输出会写到一个以 `_tok`
结尾的临时文件中。
我们有一个叫 [detok.c](detok.c)
的程序，
可以把 token 文件转储成可读形式。

解析器会输出一个以 `_sym`
结尾的符号表文件，
以及一个以 `_ast`
结尾的 AST 文件。
我们也有 [desym.c](desym.c)
和 [detree.c](detree.c)
这两个程序，
用于转储符号表和 AST 文件。

不管目标 CPU 是什么，
代码生成器一律先输出未优化的汇编代码，
文件名以 `_qbe`
结尾。
然后这个文件会被 `qbe`
或 `cpeep`
读取，
生成优化后的汇编临时文件，
文件名以 `_s`
结尾。

接下来，
汇编器把这个文件汇编成 `.o`
目标文件，
链接器再把它们链接成最终可执行文件。

和其他编译器一样，
`wcc`
也支持 `-S`
参数，
用于输出以 `.s`
结尾的汇编文件然后停止；
也支持 `-c`
参数，
用于输出目标文件然后停止。

## 符号表和 AST 文件格式

这些文件的实现方式我采取了一个非常直接的办法，
虽然肯定还有改进空间。
我就是把每个 `struct symtable`
和 `struct ASTnode`
节点
（定义在 [defs.h](defs.h)）
直接用 `fwrite()`
原样写到文件里。

其中很多节点会附带字符串：
例如符号名，
或者保存字符串字面量的 AST 节点。
对于这类情况，
我就再额外把字符串连同末尾的 NUL
一起 `fwrite()`
出去。

读回来也很直接：
先 `fread()`
一个对应大小的 struct。
不过如果节点带字符串，
还得继续把那个以 NUL 结尾的字符串读回来。
C 标准库里没有特别顺手的函数干这件事，
所以在 [misc.c](misc.c)
里我写了一个 `fgetstr()`
专门处理它。

把内存结构直接 dump 到磁盘有个明显问题：
结构体中的指针一旦写到磁盘，
它们原本的意义就没了。
等结构体重新加载进来时，
肯定会处在另一块内存区域，
所有原始指针值都会失效。

为了解决这个问题，
符号表结构和 AST 节点结构
现在都增加了数字 id，
不仅给自己编号，
也给自己指向的节点留出对应编号字段。

```
// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  int id;                       // Numeric id of the symbol
  ...
  struct symtable *ctype;       // If struct/union, ptr to that type
  int ctypeid;                  // Numeric id of that type
};

// Abstract Syntax Tree structure
struct ASTnode {
  ...
  struct ASTnode *left;         // Left, middle and right child trees
  struct ASTnode *mid;
  struct ASTnode *right;
  int nodeid;                   // Node id when tree is serialised
  int leftid;                   // Numeric ids when serialised
  int midid;
  int rightid;
  ...
};
```

读回来时的麻烦就在于：
我们必须根据这些 id
重新找到并挂接节点。
更大的问题则是：
这些文件里到底应该读多少到内存里，
又应该在内存里保留多久？

## 结构体：留在内存还是放在磁盘上

这里的矛盾很明显：
如果我们在内存里保留太多符号表节点和 AST 节点，
就会直接把内存耗尽；
但如果都丢到文件里，
又会在访问时产生大量文件读写。

这种问题通常也没有完美解，
往往就是选一个“足够好”的启发式方案。
还有一个额外限制：
即便某个启发式策略效果不错，
它本身如果需要很多实现代码，
那又会反过来进一步挤压本就紧张的内存。

所以，
我最后选了一套先能工作的办法。
它当然不是唯一选择，
但至少这是我目前手里这套。

## 写出符号表节点

解析阶段负责发现符号、
确定其类型等信息，
所以也自然由解析器负责把符号写到文件里。

编译器这里还有一个大的变化：
现在不再是一堆分散的符号表，
而是只保留一个统一符号表。
表中的每个符号现在都带有结构类型
和可见性类别，
定义在 [defs.h](defs.h)
里：

```
// A symbol in the symbol table is
// one of these structural types.
enum {
  S_VARIABLE, S_FUNCTION, S_ARRAY, S_ENUMVAL, S_STRLIT,
  S_STRUCT, S_UNION, S_ENUMTYPE, S_TYPEDEF, S_NOTATYPE
};

// Visibilty class for symbols
enum {
  V_GLOBAL,                     // Globally visible symbol
  V_EXTERN,                     // External globally visible symbol
  V_STATIC,                     // Static symbol, visible in one file
  V_LOCAL,                      // Locally visible symbol
  V_PARAM,                      // Locally visible function parameter
  V_MEMBER                      // Member of a struct or union
};
```

好吧，
我稍微撒了个小谎 :-)
实际上还是有三张符号表：
一张放普通符号，
一张放类型
（struct、union、enum、typedef），
以及一张临时表，
专门用来构建 struct、union
和函数的成员列表。

在 [sym.c](sym.c)
里，
`serialiseSym()`
会把一个符号节点以及它关联的字符串写到文件里。
这里有个小优化：
因为节点 id
是单调递增分配的，
所以我们可以记住“已经写出过的最大符号 id”，
对于不大于这个 id
的节点，
就不用反复重写。

同文件里的 `flushSymtable()`
会遍历类型列表和普通符号列表，
对每个节点调用 `serialiseSym()`。

另外，
[sym.c](sym.c)
里的 `freeSym()`
负责释放一个符号项占用的内存：
包括节点本身、
名字、
以及初始化列表
（比如全局变量 `int x= 27;`
这种）。
像 struct、union、
函数这类符号，
还会带自己的成员列表：
struct/union
的字段，
以及函数的局部变量和参数，
这些也都一并释放。

[sym.c](sym.c)
中的 `freeSymtable()`
会遍历这些链表，
并调用 `freeSym()`
逐个释放。

那么问题来了：
在解析器里，
什么时候才可以安全地 flush
并 free
符号表？
答案是：
每个函数结束后，
我们可以把符号表 flush
到磁盘；
但不能把整个表都 free
掉，
因为解析器后面仍然需要查找预定义类型和预定义符号。
例如：

```
  z= x + y;
```

这里 `x` 和 `y`
是什么类型？
是否兼容？
它们是局部变量、
参数，
还是全局变量？
甚至它们究竟有没有声明过？
这些都要求解析器保有完整符号表。

因此在 [decl.c](decl.c)
的 `function_declaration()`
末尾：

```
  ...
  flushSymtable();
  Functionid= NULL;
  return (oldfuncsym);
}
```

## 读入符号表节点

6809 代码生成器本身代码量已经很大了。
它大概会占掉 30K RAM，
所以我们必须非常节约剩下的内存。
在代码生成器这边，
我们只在真正需要时才加载符号。
并且，
一个符号往往还会带出别的符号需求：
比如某个变量可能是 `struct foo`
类型，
那我们就还得继续加载 `struct foo`
这个符号，
以及它所有字段成员对应的符号。

这里另一个麻烦是：
符号写出到文件中的顺序，
是它们被解析到的顺序；
而我们查找时，
需要按名称或按 id
来定位。
例如：

```
  struct foo x;
```

我们需要先按名字找到符号 `x`。
而 `x`
节点里又带着 `ctypeid`，
表示它依赖 `foo`
那个符号，
于是我们还得再按 id
去找这个类型节点。

绝大部分工作都由 [sym.c](sym.c)
里的 `loadSym()`
完成：

```
// Given a pointer to a symtable node, read in the next entry
// in the on-disk symbol table. Do this always if loadit is true.
// Only read one node if recurse is zero.
// If loadit is false, load the data and return true if the symbol
// a) matches the given name and stype or b) matches the id.
// Return -1 when there is nothing left to read.
static int loadSym(struct symtable *sym, char *name,
                   int stype, int id, int loadit, int recurse) {
 ...
}
```

我就不逐行讲它的实现了，
只提几个关键点。
我们可以按 `stype`
和名字来查，
比如查一个叫 `printf()`
的 `S_FUNCTION`。
也可以按数字 id
来查。
有时候我们还需要递归把后续节点一并读进来：
例如某个带成员的符号
（像 struct）
在写出文件时，
后面会紧跟它的成员节点。
另外，
当 `loadit`
被设置时，
我们也可以无条件地直接把下一个符号读出来，
例如在读取成员列表时就会这样。

`findSyminfile()`
这个函数很简单粗暴：
每次都回到符号文件开头，
循环调用 `loadSym()`，
要么找到需要的符号，
要么读到文件末尾。
对，
这听起来就不怎么高效。

旧版编译器里原本就有这些函数：

```
struct symtable *findlocl(char *name, int id);
struct symtable *findSymbol(char *name, int stype, int id);
struct symtable *findmember(char *s);
struct symtable *findstruct(char *s);
struct symtable *findunion(char *s);
struct symtable *findenumtype(char *s);
struct symtable *findenumval(char *s);
struct symtable *findtypedef(char *s);
```

它们现在还在，
但实现不同了。
流程是：
先在内存中查找需要的符号；
如果没找到，
再调用 `findSyminfile()`。
而一旦某个符号从文件中被加载进来，
它就会被挂到当前内存中的符号表里。
也就是说，
代码生成器其实在逐步构建一份“按需缓存”的符号表。

为了节省内存，
代码生成器也需要定期 flush
和 free
内存里的符号表。
在 [cgen.c](cgen.c)
中，
主循环大概是这样：

```
  while (1) {
    // Read the next function's top node in from file
    node= loadASTnode(0, 1);
    if (node==NULL) break;

    // Generate the assembly code for the tree
    genAST(node, NOLABEL, NOLABEL, NOLABEL, 0);

    // Free the symbols in the in-memory symbol tables.
    freeSymtable();
  }
```

我重写编译器时还踩到过一个小坑：
有些全局符号带初始化值，
需要生成相应的汇编。
所以就在上面这个循环之前，
还会先调用一个叫 `allocateGlobals()`
的函数。
它内部又会调用 [sym.c](sym.c)
里的 `loadGlobals()`，
把所有全局符号读进来，
然后我们再遍历全局符号列表，
调用对应的代码生成器函数。
`allocateGlobals()`
结束后，
就可以再 `freeSymtable()`。

最后我想补一句：
这一套现在能工作，
是因为单个 C 程序里真正的符号数量
还没那么夸张，
即便把头文件里带进来的东西也算上。
可如果这是一个真实的生产级编译器，
跑在真正的类 Unix 系统上，
那情况就会崩掉。
现实里一个普通程序可能就会引入十来个头文件，
每个头文件里又有一堆 typedef、
struct、
enum
等等，
那内存很快就会被吃光。

所以这套方案能用，
但不具备可扩展性。

## 写出 AST 节点

接下来轮到 AST 节点。
首先必须明确一点：
内存根本不够你把某个函数的整棵 AST 树构建完，
再一次性写出
（或者读回）。
我们需要处理的较大函数，
经常会有 3,000 个以上 AST 节点。
光它们自己就足以压垮 64K RAM。

所以，
我们只能在内存里保留有限数量的 AST 节点。
但该怎么做？
毕竟这是一棵树。
对于任何一个节点，
它下面的子树到底什么时候还需要，
什么时候就可以修剪掉？

在顶层解析器文件 [parse.c](parse.c)
里，
有个 `serialiseAST()`
函数，
负责把给定节点及其子节点写到磁盘。
这个函数会在几处地方被调用。

例如在 [stmt.c](stmt.c)
的 `compound_statement()`
中：

```
  while (1) {
    ...
    // Parse a single statement
    tree = single_statement();

    ...
        left = mkastnode(A_GLUE, P_NONE, NULL, left, NULL, tree, NULL, 0);

        // To conserve memory, we try to optimise the single statement tree.
        // Then we serialise the tree and free it. We set the right pointer
        // in left NULL; this will stop the serialiser from descending into
        // the tree that we already serialised.
        tree = optimise(tree);
        serialiseAST(tree);
        freetree(tree, 0);
    ...
  }
```

也就是说，
每解析出一条语句，
我们就为它构建 AST 树，
然后马上把这棵树写到磁盘。

而在 [decl.c](decl.c)
的 `function_declaration()`
末尾：

```
  // Serialise the tree
  serialiseAST(tree);
  freetree(tree, 0);

  // Flush out the in-memory symbol table.
  // We are no longer in a function.
  flushSymtable();
  Functionid= NULL;

  return (oldfuncsym);
```

这里则是把那个标识“函数顶层 AST 节点”的 `S_FUNCTION`
节点写出去。

上面的代码还提到了 `freetree()`。
它在 [tree.c](tree.c)
里是这样的：

```
// Free the contents of a tree. Possibly
// because of tree optimisation, sometimes
// left and right are the same sub-nodes.
// Free the names if asked to do so.
void freetree(struct ASTnode *tree, int freenames) {
  if (tree==NULL) return;

  if (tree->left!=NULL) freetree(tree->left, freenames);
  if (tree->mid!=NULL) freetree(tree->mid, freenames);
  if (tree->right!=NULL && tree->right!=tree->left)
                                        freetree(tree->right, freenames);
  if (freenames && tree->name != NULL) free(tree->name);
  free(tree);
}
```

## 读入 AST 节点

我为了找到“怎样把 AST 节点重新读回代码生成器”这件事，
确实折腾了很久。
这里要完成两件事：

1. 找到每个函数对应的顶层 AST 节点并把它读进来。
2. 一旦有了某个 AST 节点，
   就根据它的子节点 id
   继续把孩子节点读进来。

我最开始的方案，
和符号表一样，
是每次查找时都回到文件开头重新扫。
结果如何？
一份 1,000 行的源文件，
编译一遍要 45 分钟左右。
显然这不行。

我也想过，
是不是可以在内存里缓存所有 AST 节点的
数字 id、
类型
（是否是 `S_FUNCTION`）
以及文件偏移量。
但这也行不通。
对每个 AST 节点来说，
需要：

 - 2 字节存 id
 - 1 字节存 `S_FUNCTION` 布尔值
 - 4 字节存文件偏移

如果一个 AST 文件有 3,000 个节点，
那光这个缓存就要 21,000 字节内存。
太荒唐了。

于是我换了个办法：
额外生成一个独立的临时文件，
里面保存“节点 id -> 文件偏移量”的映射。
这是由 [tree.c](tree.c)
中的 `mkASTidxfile()`
完成的。
这个文件的内容非常简单，
就是一串偏移量值，
每个占 4 字节。
位置 0
记录 id 0
的偏移，
位置 4
记录 id 1
的偏移，
依此类推。

另外，
由于我们还需要顺序找到每个函数的顶层节点，
而一个文件里的函数数通常并不算多，
所以我选择把所有 `S_FUNCTION`
节点的偏移量另外保存在一份内存列表里。

在 [tree.c](tree.c)
里：

```
// We keep an array of AST node offsets that
// represent the functions in the AST file
long *Funcoffset;

```

它会通过 `malloc()`
和 `realloc()`
不断扩展，
直到收集完所有函数偏移。
最后一个值会是 0，
因为解析器中 id 0
从来不会真的分配给 AST 节点。

那这些信息最终是怎么用的？
同样在 [tree.c](tree.c)
里有一个 `loadASTnode()`
函数：

```
// Given an AST node id, load that AST node from the AST file.
// If nextfunc is set, find the next AST node which is a function.
// Allocate and return the node or NULL if it can't be found.
struct ASTnode *loadASTnode(int id, int nextfunc) {
  ...
}
```

它既可以按 id
加载某个节点，
也可以直接取下一个 `S_FUNCTION`
节点。
借助那份偏移索引文件，
我们就能很快定位到主 AST 文件中想要的节点位置。
简单直接。

## 使用 `loadASTnode()` 和释放 AST 节点

遗憾的是，
并不存在某个“只改一处就够了”的位置来调用 `loadASTnode()`。
在架构无关的生成代码
[gen.c](gen.c)
中，
凡是以前直接使用 `n->left`、
`n->mid`
或 `n->right`
指针的地方，
现在都必须改成调用 `loadASTnode()`，
例如：

```
// Given an AST, an optional label, and the AST op
// of the parent, generate assembly code recursively.
// Return the register id with the tree's final value.
int genAST(struct ASTnode *n, int iflabel, int looptoplabel,
           int loopendlabel, int parentASTop) {
  struct ASTnode *nleft, *nmid, *nright;

  // Load in the sub-nodes
  nleft=loadASTnode(n->leftid,0);
  nmid=loadASTnode(n->midid,0);
  nright=loadASTnode(n->rightid,0);
  ...
}
```

你会在 [gen.c](gen.c)
里找到大约 15 处对 `loadASTnode()`
的调用。

回到解析器那边，
我们可以在写出一条语句后，
立刻对整棵树调用 `freetree()`。
而在代码生成器这边，
我决定做得更具体一些。
一旦我确定某个 AST 节点已经彻底用完，
就调用 [tree.c](tree.c)
里的 `freeASTnode()`
来释放它。
在代码生成器中，
大概有 12 处会这样做。

关于符号表和 AST 节点的处理改动，
大致就这些。

## 通用内存释放

前面在说“怎样把编译器塞进 64K”时，
我的第三点是：
尽可能使用 `free()`
对不用的数据结构做垃圾回收。

而 C 大概是最不适合拿来做垃圾回收的语言之一！
我有段时间到处试着撒 `free()`，
觉得哪里应该可以释放就往哪放，
结果编译器不是直接 segfault，
就是更糟：
继续访问一块已经被覆盖的节点内存，
然后进入彻底疯狂状态。

好在最后我把主要的垃圾回收收敛到了四个函数里：
`freeSym()`、
`freeSymtable()`、
`freeASTnode()`
和 `freetree()`。

不过这依然没彻底解决所有内存回收问题。
最近我已经开始借助
[Valgrind](https://valgrind.org/)
来找内存泄漏。
我一般会先盯最严重的几个案例，
再想办法看看哪里还能插入一个有帮助的 `free()`。
也正是靠这种方式，
我总算把编译器推进到了“能够在 6809 上自编译”的程度，
但显然仍然还有很多改进空间。

## Peephole 优化器

这个 peephole 优化器 [cpeep.c](cpeep.c)
最早是 Christian W. Fraser
在 1984 年写的。
从它的 [文档](docs/copt.1)
来看，
后来又有好几个人继续维护过。
我是从
[Fuzix Compiler Kit](https://github.com/EtchedPixels/Fuzix-Compiler-Kit)
里把它导入进来的，
同时也改了名字。
我还把规则终止符从“空行”
改成了 `====`，
因为这样我自己看起来更容易分辨规则边界。

6809 后端有时会吐出相当糟糕的代码。
这个优化器能帮忙消掉其中一部分。
你可以去看
[rules.6809](lib/6809/rules.6809)
了解有哪些规则；
我觉得自己已经写了足够多的注释。
另外我还有一个
[测试文件](tests/input.rules.6809)，
专门用来验证这些规则是否工作正常。

## 构建并运行编译器：QBE 版本

如果你想在 Linux 机器上构建这个编译器，
并让它输出 x64 代码，
那首先需要下载
[QBE 1.2](https://c9x.me/compile/releases.html)，
把它编译出来，
再把 `qbe`
安装到你的 `$PATH`
里某个可见位置。

接着，
你需要创建 `/opt/wcc`
目录，
并让它对当前用户可写。

然后执行 `make; make install`，
编译器就会被构建出来。
可执行文件会安装到 `/opt/wcc/bin`，
头文件会放到 `/opt/wcc/include`，
6809 的库文件会放到 `/opt/wcc/lib/6809`。

接下来确保 `/opt/wcc/bin/wcc`
（也就是编译器前端）
在你的 `$PATH`
中。
我自己通常会在私人 `bin`
目录里做一个指向它的 symlink。

完成这些之后，
你就可以执行 `make test`，
它会进入 `tests/`
目录并运行里面所有测试。

## 构建并运行编译器：6809 版本

这一套会复杂一些。

首先，
你需要下载
[Fuzix Bintools](https://github.com/EtchedPixels/Fuzix-Bintools)，
至少把其中的汇编器 `as6809`
和链接器 `ld6809`
编出来，
然后把它们安装到你的 `$PATH`
里。

接着，
下载我的
[Fuzemsys](https://github.com/DoctorWkt/Fuzemsys)
项目。
这里面带有一个 6809 模拟器，
我们需要靠它来运行 6809 的二进制文件。
进入 `emulators/`
目录，
执行 `make emu6809`。
编译完成后，
把模拟器也安装到你的 `$PATH`
里。

如果你还没建过 `/opt/wcc`
目录，
就像前面那样建好它。
然后回到本项目，
执行 `make; make install`
完成安装。
同样要确保 `/opt/wcc/bin/wcc`
这个前端程序在你的 `$PATH`
中。

接下来，
你就可以执行 `make 6test`，
它会进入 `tests/`
目录并运行所有测试。
这一次，
我们生成的是 6809 二进制，
然后借助 6809 模拟器来运行它们。

## 进行 QBE Triple Test

当你安装好了 `qbe`，
也已经完成 `make install; make test`
确认编译器能正常工作后，
就可以执行 `make triple`。
它会：

 - 用你的本机编译器构建编译器，
 - 用编译器自己再构建一份放到 `L1`
   目录中，
 - 再次用它自己构建一份放到 `L2`
   目录中，
 - 然后对 `L1`
   和 `L2`
   的可执行文件做校验和比较，
   以确认它们完全一致：

```
0f14b990d9a48352c4d883cd550720b3  L1/detok
0f14b990d9a48352c4d883cd550720b3  L2/detok
3cc59102c6a5dcc1661b3ab3dcce5191  L1/cgenqbe
3cc59102c6a5dcc1661b3ab3dcce5191  L2/cgenqbe
3e036c748bdb5e3ffc0e03506ed00243  L2/wcc      <-- different
6fa26e506a597c9d9cfde7d168ae4640  L1/detree
6fa26e506a597c9d9cfde7d168ae4640  L2/detree
7f8e55a544400ab799f2357ee9cc4b44  L1/cscan
7f8e55a544400ab799f2357ee9cc4b44  L2/cscan
912ebc765c27a064226e9743eea3dd30  L1/wcc      <-- different
9c6a66e8b8bbc2d436266c5a3ca622c7  L1/cparseqbe
9c6a66e8b8bbc2d436266c5a3ca622c7  L2/cparseqbe
cb493abe1feed812fb4bb5c958a8cf83  L1/desym
cb493abe1feed812fb4bb5c958a8cf83  L2/desym
```

这里 `wcc`
二进制之所以不同，
是因为一个内部保存的是 `L1`
目录路径，
另一个保存的是 `L2`
目录路径，
用于定位各编译阶段的可执行文件。

## 进行 6809 Triple Test

这件事我没有用 `Makefile`
直接做，
而是单独写了一个 Bash 脚本，
叫 `6809triple_test`。
运行它会：

 - 先用你的本机编译器构建编译器，
 - 再用编译器自己构建出 6809 版本放到 `L1`
   目录，
 - 然后再用它自己构建一遍放到 `L2`
   目录。

这一步非常慢！
在我那台还算不错的笔记本上，
也得花大约 45 分钟。
最后你可以自己做校验和比较，
确认可执行文件是否完全一致：

```
$ md5sum L1/_* L2/_* | sort
01c5120e56cb299bf0063a07e38ec2b9  L1/_cgen6809
01c5120e56cb299bf0063a07e38ec2b9  L2/_cgen6809
0caee9118cb7745eaf40970677897dbf  L1/_detree
0caee9118cb7745eaf40970677897dbf  L2/_detree
2d333482ad8b4a886b5b78a4a49f3bb5  L1/_detok
2d333482ad8b4a886b5b78a4a49f3bb5  L2/_detok
d507bd89c0fc1439efe2dffc5d8edfe3  L1/_desym
d507bd89c0fc1439efe2dffc5d8edfe3  L2/_desym
e78da1f3003d87ca852f682adc4214e8  L1/_cscan
e78da1f3003d87ca852f682adc4214e8  L2/_cscan
e9c8b2c12ea5bd4f62091fafaae45971  L1/_cparse6809
e9c8b2c12ea5bd4f62091fafaae45971  L2/_cparse6809
```

目前我在直接运行 6809 可执行版 `wcc`
时还有些问题，
所以我现在仍然用 x64
版本的 `wcc`
来驱动整个流程。

## 一组实际命令行操作示例

下面是我当时用过的整套命令记录：

```
# Download the acwj repository
cd /usr/local/src
git clone https://github.com/DoctorWkt/acwj

# Make the destination directory
sudo mkdir /opt/wcc
sudo chown wkt:wkt /opt/wcc

# Install QBE
cd /usr/local/src
wget https://c9x.me/compile/release/qbe-1.2.tar.xz
xz -d qbe-1.2.tar.xz 
tar vxf qbe-1.2.tar 
cd qbe-1.2/
make
sudo make install

# Install the wcc compiler
cd /usr/local/src/acwj/64_6809_Target
make install

# Put wcc on my $PATH
cd ~/.bin
ln -s /opt/wcc/bin/wcc .

# Do the triple test on x64 using QBE
cd /usr/local/src/acwj/64_6809_Target
make triple

# Get the Fuzix-Bintools and build
# the 6809 assembler and linker
cd /usr/local/src
git clone https://github.com/EtchedPixels/Fuzix-Bintools
cd Fuzix-Bintools/
make as6809 ld6809
cp as6809 ld6809 ~/.bin

# Get Fuzemsys and build the 6809 emulator.
# I needed to install the readline library.
sudo apt-get install libreadline-dev
cd /usr/local/src
git clone https://github.com/DoctorWkt/Fuzemsys
cd Fuzemsys/emulators/
make emu6809
cp emu6809 ~/.bin

# Go back to the compiler and do the
# triple test using the 6809 emulator
cd /usr/local/src/acwj/64_6809_Target
./6809triple_test 
```

## 这真的算自编译吗

我们确实可以在 6809 上通过 triple test。
但问题是：
这真的算自编译吗？
答案是：算，
但它绝对 *不是* self-hosting。

这套 C 编译器当前 *无法* 自己构建出来的东西包括：

 - C 预处理器
 - peephole 优化器
 - 6809 汇编器
 - 6809 链接器
 - 面向 6809 的 `ar` 归档器
 - 编译器辅助函数和 C 库。
   目前这些仍然是用 Fuzix Compiler Kit
   来构建的。
   Fuzix Compiler 能理解“真正的”C，
   而这个编译器目前只懂 C 的一个子集，
   所以它还构建不了这些函数。

因此，
如果我真的想把这一整套东西搬到
[MMU09 SBC](https://github.com/DoctorWkt/MMU09)
上，
那我仍然需要借助 Fuzix Compiler
去构建汇编器、
链接器、
辅助函数
和 C 库。

换句话说，
“acwj” 编译器现在确实能够读取“已经预处理过的 C 源码”，
通过扫描器、
解析器
和代码生成器输出 6809 汇编；
而且它还能对自己的源码做这件事。

这足以说明：
它是一个 self-compiling compiler，
但还不是 self-hosting compiler。

## 后续工作

现在这还不是一套生产级编译器。
严格来说，
它甚至都还不是一个完整的 C 编译器，
因为它只懂 C 语言的一个子集。

接下来还可以做的事情包括：

 - 提高健壮性
 - 继续解决垃圾回收问题
 - 加入无符号类型
 - 加入 float 和 double
 - 支持更多真实 C 语言特性，
   直到真正变成 self-hosting
 - 提高 6809 代码生成器的质量
 - 提高 6809 编译器本身的速度
 - 或者干脆退后一步，
   吸收这整个旅程里学到的经验，
   从零重写一个全新的编译器！

## 总结

做到这一部分时，
我已经相当疲惫了。
这几个月的工作量，
其实从我的
[笔记](docs/NOTES.md)
里就能看出来。
而现在整个 “acwj” 旅程也已经来到第 64 部分；
这倒还是个不错的二次幂数字 :-)

所以我不能百分之百说“绝对不会再继续”，
但我觉得这大概就是
“acwj”
旅程的终点了。
如果你一路跟到了这里，
无论是读过其中一部分、
大部分，
还是全部内容，
都感谢你愿意花时间看完这些笔记。
我希望它们对你是有帮助的。

而现在，
如果你正好需要一套“差不多算 C 编译器”的东西，
目标又是寄存器不多的 8 位或 16 位 CPU，
那这份项目也许能成为一个起点。

Cheers，Warren
