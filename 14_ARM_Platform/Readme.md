# 第 14 部分：生成 ARM 汇编代码

在编译器编写之旅的这一部分中，
我已经把编译器移植到了
[Raspberry Pi 4](https://en.wikipedia.org/wiki/Raspberry_Pi)
所使用的 ARM CPU 上。

这一节开始前我得先说明一下：
我对 MIPS 汇编语言相当熟，
但在开始这段旅程时，
我只懂一点点 x86-32 汇编，
对 x86-64 和 ARM 汇编几乎一无所知。

这一路上我采取的办法是：
写一些示例 C 程序，
然后让不同的 C 编译器把它们编译成汇编，
观察它们到底会生成什么样的汇编代码。
这一次为了给我们的编译器写 ARM 输出，
我也是这么做的。

## 主要差异

首先，ARM 是 RISC CPU，而 x86-64 是 CISC CPU。
与 x86-64 相比，ARM 的寻址模式更少。
此外，在生成 ARM 汇编代码时，
还会遇到一些其他有意思的限制。
因此我会先讲主要差异，
把两者之间那些主要的相似点放到后面。

### ARM 寄存器

ARM 的寄存器数量远多于 x86-64。
即便如此，我仍然只打算分配四个寄存器来使用：
`r4`、`r5`、`r6` 和 `r7`。
后面会看到，`r0` 和 `r3` 会被拿去做别的事情。

### 全局变量的寻址

在 x86-64 上，
我们只需要用下面这样的语句来声明全局变量：

```
        .comm   i,4,4        # int variable
        .comm   j,1,1        # char variable
``` 

之后再对这些变量进行加载和存储就很容易：

```
        movb    %r8b, j(%rip)    # Store to j
        movl    %r8d, i(%rip)    # Store to i
        movzbl  i(%rip), %r8     # Load from i
        movzbq  j(%rip), %r8     # Load from j
```

但在 ARM 上，
我们必须在程序后导代码里手工为所有全局变量分配空间：

```
        .comm   i,4,4
        .comm   j,1,1
...
.L2:
        .word i
        .word j
```

为了访问它们，
我们需要先把变量地址加载进一个寄存器，
再通过第二步从这个地址里取值：

```
        ldr     r3, .L2+0
        ldr     r4, [r3]        # Load i
        ldr     r3, .L2+4
        ldr     r4, [r3]        # Load j
```

对变量的存储也类似：

```
        mov     r4, #20
        ldr     r3, .L2+4
        strb    r4, [r3]        # i= 20
        mov     r4, #10
        ldr     r3, .L2+0
        str     r4, [r3]        # j= 10
```

因此现在 `cgpostamble()` 中多了下面这段逻辑，
用来生成 `.word` 表：

```c
  // Print out the global variables
  fprintf(Outfile, ".L2:\n");
  for (int i = 0; i < Globs; i++) {
    if (Gsym[i].stype == S_VARIABLE)
      fprintf(Outfile, "\t.word %s\n", Gsym[i].name);
  }
```

这也意味着：
我们必须知道每个全局变量相对于 `.L2` 的偏移量。
按照 KISS 原则，
我现在每次想把变量地址加载到 `r3` 时，
都现场手动计算一次偏移。
对，我知道更合理的做法是只算一次然后缓存起来；以后再说！

```c
// Determine the offset of a variable from the .L2
// label. Yes, this is inefficient code.
static void set_var_offset(int id) {
  int offset = 0;
  // Walk the symbol table up to id.
  // Find S_VARIABLEs and add on 4 until
  // we get to our variable

  for (int i = 0; i < id; i++) {
    if (Gsym[i].stype == S_VARIABLE)
      offset += 4;
  }
  // Load r3 with this offset
  fprintf(Outfile, "\tldr\tr3, .L2+%d\n", offset);
}
```

### 加载整数字面量

ARM 中加载指令里可直接放入的整数字面量大小有限，
我理解它大概只有 11 位，而且可能还是带符号值。
这就意味着，
较大的整数字面量无法用一条指令直接装进去。

解决办法是像变量一样，把这些字面量也存在内存里。
因此我维护了一个“已经使用过的整数字面量”列表。
在后导代码中，
我会把它们输出到 `.L3` 标签之后。
然后和变量一样，
通过遍历这个列表来确定某个字面量相对于 `.L3` 的偏移：

```c
// We have to store large integer literal values in memory.
// Keep a list of them which will be output in the postamble
#define MAXINTS 1024
int Intlist[MAXINTS];
static int Intslot = 0;

// Determine the offset of a large integer
// literal from the .L3 label. If the integer
// isn't in the list, add it.
static void set_int_offset(int val) {
  int offset = -1;

  // See if it is already there
  for (int i = 0; i < Intslot; i++) {
    if (Intlist[i] == val) {
      offset = 4 * i;
      break;
    }
  }

  // Not in the list, so add it
  if (offset == -1) {
    offset = 4 * Intslot;
    if (Intslot == MAXINTS)
      fatal("Out of int slots in set_int_offset()");
    Intlist[Intslot++] = val;
  }
  // Load r3 with this offset
  fprintf(Outfile, "\tldr\tr3, .L3+%d\n", offset);
}
```

### 函数前导代码

下面我要给出函数前导代码，
不过说实话，我并不完全确定每条指令到底在干什么。
下面是 `int main(int x)` 的版本：

```
  .text
  .globl        main
  .type         main, %function
  main:         push  {fp, lr}          # Save the frame and stack pointers
                add   fp, sp, #4        # Add sp+4 to the stack pointer
                sub   sp, sp, #8        # Lower the stack pointer by 8
                str   r0, [fp, #-8]     # Save the argument as a local var?
```

而下面是用于返回单个值的函数后导代码：

```
                sub   sp, fp, #4        # ???
                pop   {fp, pc}          # Pop the frame and stack pointers
```

### 比较后返回 0 或 1

在 x86-64 上，
有像 `sete` 这样的指令，
可以根据比较结果把寄存器设成 0 或 1，
然后再通过 `movzbq` 把剩余高位清零。
而在 ARM 上，
我们会用两条独立指令：
当条件为真时把寄存器设为某个值，
当条件为假时再设为另一个值，例如：

```
                moveq r4, #1            # Set r4 to 1 if values were equal
                movne r4, #0            # Set r4 to 0 if values were not equal
```

## 对比相近的 x86-64 与 ARM 汇编输出

我想这差不多就是主要差异了。
下面列出 `cgXXX()` 操作、
该操作相关的具体类型，
以及对应的 x86-64 和 ARM 指令序列示例。

| Operation(type) | x86-64 Version | ARM Version |
|-----------------|----------------|-------------|
cgloadint() | movq $12, %r8 | mov r4, #13 |
cgloadglob(char) | movzbq foo(%rip), %r8 | ldr r3, .L2+#4 |
| | | ldr r4, [r3] |
cgloadglob(int) | movzbl foo(%rip), %r8 | ldr r3, .L2+#4 |
| | | ldr r4, [r3] |
cgloadglob(long) | movq foo(%rip), %r8 | ldr r3, .L2+#4 |
| | | ldr r4, [r3] |
int cgadd() | addq %r8, %r9 | add r4, r4, r5 |
int cgsub() | subq %r8, %r9 | sub r4, r4, r5 |
int cgmul() | imulq %r8, %r9 | mul r4, r4, r5 |
int cgdiv() | movq %r8,%rax | mov r0, r4 |
| | cqo | mov r1, r5 |
| | idivq %r8 | bl __aeabi_idiv |
| | movq %rax,%r8 | mov r4, r0 |
cgprintint() | movq %r8, %rdi | mov r0, r4 |
| | call printint | bl printint |
| | | nop |
cgcall() | movq %r8, %rdi | mov r0, r4 |
| | call foo | bl foo |
| | movq %rax, %r8 | mov r4, r0 |
cgstorglob(char) | movb %r8, foo(%rip) | ldr r3, .L2+#4 |
| | | strb r4, [r3] |
cgstorglob(int) | movl %r8, foo(%rip) | ldr r3, .L2+#4 |
| | | str r4, [r3] |
cgstorglob(long) | movq %r8, foo(%rip) | ldr r3, .L2+#4 |
| | | str r4, [r3] |
cgcompare_and_set() | cmpq %r8, %r9 | cmp r4, r5 |
| | sete %r8 | moveq r4, #1 |
| | movzbq %r8, %r8 | movne r4, #1 |
cgcompare_and_jump() | cmpq %r8, %r9 | cmp r4, r5 |
| | je L2 | beq L2 |
cgreturn(char) | movzbl %r8, %eax | mov r0, r4 |
| | jmp L2 | b L2 |
cgreturn(int) | movl %r8, %eax | mov r0, r4 |
| | jmp L2 | b L2 |
cgreturn(long) | movq %r8, %rax | mov r0, r4 |
| | jmp L2 | b L2 |

## 测试 ARM 代码生成器

如果你把这一部分旅程中的编译器拷到 Raspberry Pi 3 或 4 上，
就应该可以执行：

```
$ make armtest
cc -o comp1arm -g -Wall cg_arm.c decl.c expr.c gen.c main.c misc.c
      scan.c stmt.c sym.c tree.c types.c
cp comp1arm comp1
(cd tests; chmod +x runtests; ./runtests)
input01: OK
input02: OK
input03: OK
input04: OK
input05: OK
input06: OK
input07: OK
input08: OK
input09: OK
input10: OK
input11: OK
input12: OK
input13: OK
input14: OK

$ make armtest14
./comp1 tests/input14
cc -o out out.s lib/printint.c
./out
10
20
30
```

## 总结与下一步

为了让 ARM 版代码生成器 `cg_arm.c`
正确编译所有测试输入，
我确实花了不少时间挠头。
但总体来说，它还是比较直接的，
只是我自己对这套架构和指令集不熟。

如果一个平台只有 3 到 4 个寄存器、
2 种左右数据宽度，
并且有栈（以及栈帧），
那么把编译器移植过去应该都不会太难。
后面继续推进时，
我会尽量保持 `cg.c` 和 `cg_arm.c`
在功能上同步。

在编译器编写之旅的下一部分中，
我们将把 `char` 指针，以及一元运算符 `*` 和 `&` 加入语言。 [下一步](../15_Pointers_pt1/Readme.md)
