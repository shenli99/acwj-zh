# 第 4 部分：一个真正的编译器

差不多该兑现我“真的要写一个编译器”的承诺了。
所以在这部分旅程中，我们将把程序里的解释器替换成
会生成 x86-64 汇编代码的实现。

## 重新审视解释器

在开始之前，值得先回顾一下 `interp.c` 里的解释器代码：

```c
int interpretAST(struct ASTnode *n) {
  int leftval, rightval;

  if (n->left) leftval = interpretAST(n->left);
  if (n->right) rightval = interpretAST(n->right);

  switch (n->op) {
    case A_ADD:      return (leftval + rightval);
    case A_SUBTRACT: return (leftval - rightval);
    case A_MULTIPLY: return (leftval * rightval);
    case A_DIVIDE:   return (leftval / rightval);
    case A_INTLIT:   return (n->intvalue);

    default:
      fprintf(stderr, "Unknown AST operator %d\n", n->op);
      exit(1);
  }
}
```

`interpretAST()` 会以深度优先（depth-first）的方式遍历给定的 AST。
它先求值左子树，再求值右子树。
最后使用当前节点根部的 `op` 值，对这两个子树的结果执行操作。

如果 `op` 值是四个数学运算符之一，那就执行相应的数学运算。
如果 `op` 值表示当前节点只是一个整数字面量，
那就直接返回这个字面量的值。

这个函数会返回当前树的最终结果。
而由于它本身是递归的，因此它会一层层地把整棵树的值算出来。

## 改成生成汇编代码

我们将要编写一个通用的汇编代码生成器。
而这个生成器再进一步调用一组与具体 CPU 相关的代码生成函数。

下面就是 `gen.c` 里的通用汇编代码生成器：

```c
// Given an AST, generate
// assembly code recursively
static int genAST(struct ASTnode *n) {
  int leftreg, rightreg;

  // Get the left and right sub-tree values
  if (n->left) leftreg = genAST(n->left);
  if (n->right) rightreg = genAST(n->right);

  switch (n->op) {
    case A_ADD:      return (cgadd(leftreg,rightreg));
    case A_SUBTRACT: return (cgsub(leftreg,rightreg));
    case A_MULTIPLY: return (cgmul(leftreg,rightreg));
    case A_DIVIDE:   return (cgdiv(leftreg,rightreg));
    case A_INTLIT:   return (cgload(n->intvalue));

    default:
      fprintf(stderr, "Unknown AST operator %d\n", n->op);
      exit(1);
  }
}
```

看起来很眼熟，对吧？我们做的仍然是同样的深度优先树遍历。
只不过这一次：

  + `A_INTLIT`：把字面量值装载进一个寄存器
  + 其他运算符：对保存了左孩子值和右孩子值的两个寄存器执行数学运算

`genAST()` 不再在函数之间传递数值，
而是传递寄存器标识符。
例如 `cgload()` 会把一个值装入某个寄存器，
并返回这个寄存器的编号。

`genAST()` 自己返回的，也是“当前这棵树最终结果所在寄存器”的编号。
这就是为什么前面的代码要先取到左右寄存器标识：

```c
  if (n->left) leftreg = genAST(n->left);
  if (n->right) rightreg = genAST(n->right);
```

## 调用 `genAST()`

`genAST()` 只负责算出传给它的表达式值。
但我们还需要把最终计算结果打印出来。
同时，我们也需要在生成的汇编代码前后包上一些固定内容：
前面是 *preamble*（前导代码），后面是 *postamble*（收尾代码）。
这些都由 `gen.c` 里的另一个函数完成：

```c
void generatecode(struct ASTnode *n) {
  int reg;

  cgpreamble();
  reg= genAST(n);
  cgprintint(reg);      // Print the register with the result as an int
  cgpostamble();
}
```

## x86-64 代码生成器

通用代码生成器部分到这里就差不多了。
现在该看看真正的汇编代码是怎么生成的。
目前我把目标平台定为 x86-64，
因为它仍然是 Linux 上最常见的平台之一。
所以，打开 `cg.c`，开始看看里面的内容。

### 分配寄存器

任何 CPU 的寄存器数量都是有限的。
我们需要分配寄存器来保存整数字面量，
以及对它们执行运算时产生的中间结果。
不过，一旦某个值已经用完，往往就可以丢弃它，
进而释放保存它的寄存器。
随后这个寄存器就能被重新利用。

下面这三个函数负责寄存器分配：

 + `freeall_registers()`：把所有寄存器都标记为可用
 + `alloc_register()`：分配一个空闲寄存器
 + `free_register()`：释放一个已分配的寄存器

这些代码本身比较直接，只带了一些错误检查，所以我就不逐行讲了。
目前如果寄存器用光，程序会直接崩溃。
后面我会再处理“没有空闲寄存器可用”时该怎么办。

代码操作的是抽象寄存器：r0、r1、r2 和 r3。
真正的寄存器名字保存在下面这个字符串表里：

```c
static char *reglist[4]= { "%r8", "%r9", "%r10", "%r11" };
```

这让这些函数相对独立于具体 CPU 架构。

### 装载一个寄存器

这由 `cgload()` 完成：先分配一个寄存器，
然后用一条 `movq` 指令把字面量值加载进去。

```c
// Load an integer literal value into a register.
// Return the number of the register
int cgload(int value) {

  // Get a new register
  int r= alloc_register();

  // Print out the code to initialise it
  fprintf(Outfile, "\tmovq\t$%d, %s\n", value, reglist[r]);
  return(r);
}
```

### 两个寄存器相加

`cgadd()` 接收两个寄存器编号，并生成把它们相加的代码。
结果保存在其中一个寄存器里，
另一个寄存器则被释放以备后用：

```c
// Add two registers together and return
// the number of the register with the result
int cgadd(int r1, int r2) {
  fprintf(Outfile, "\taddq\t%s, %s\n", reglist[r1], reglist[r2]);
  free_register(r1);
  return(r2);
}
```

注意，加法是*可交换（commutative）*的，
所以我本来也可以把 `r2` 加到 `r1` 上，而不是把 `r1` 加到 `r2` 上。
函数返回的是保存最终结果的寄存器编号。

### 两个寄存器相乘

这和加法非常相似，而且乘法同样是*可交换*的，
因此任意一个寄存器都可以作为结果寄存器返回：

```c
// Multiply two registers together and return
// the number of the register with the result
int cgmul(int r1, int r2) {
  fprintf(Outfile, "\timulq\t%s, %s\n", reglist[r1], reglist[r2]);
  free_register(r1);
  return(r2);
}
```

### 两个寄存器相减

减法就*不可交换*了：顺序必须正确。
第二个寄存器要从第一个寄存器中减掉，
所以我们返回第一个寄存器，并释放第二个：

```c
// Subtract the second register from the first and
// return the number of the register with the result
int cgsub(int r1, int r2) {
  fprintf(Outfile, "\tsubq\t%s, %s\n", reglist[r2], reglist[r1]);
  free_register(r2);
  return(r1);
}
```

### 两个寄存器相除

除法同样不可交换，因此上面的说明依旧成立。
而在 x86-64 上，它甚至还要更复杂一些。
我们需要先把来自 `r1` 的*被除数（dividend）*加载到 `%rax` 中。
随后用 `cqo` 把它扩展成八字节。
然后 `idivq` 会用 `%rax` 去除以 `r2` 中的除数，
并把*商（quotient）*留在 `%rax` 里，
所以我们还得把结果再拷贝回 `r1` 或 `r2` 中的一个。
最后就可以释放另一个寄存器了。

```c
// Divide the first register by the second and
// return the number of the register with the result
int cgdiv(int r1, int r2) {
  fprintf(Outfile, "\tmovq\t%s,%%rax\n", reglist[r1]);
  fprintf(Outfile, "\tcqo\n");
  fprintf(Outfile, "\tidivq\t%s\n", reglist[r2]);
  fprintf(Outfile, "\tmovq\t%%rax,%s\n", reglist[r1]);
  free_register(r2);
  return(r1);
}
```

### 打印一个寄存器

x86-64 并没有一条能把寄存器内容直接按十进制打印出来的指令。
为了解决这个问题，汇编前导代码里包含了一个叫做 `printint()` 的函数，
它接收一个寄存器参数，然后调用 `printf()` 以十进制方式打印它。

我这里就不贴 `cgpreamble()` 的代码了，
不过它也包含了 `main()` 的开头部分，
这样我们输出的汇编文件就能被组装成一个完整程序。
而 `cgpostamble()` 的代码我也不贴了，
它只是简单地调用 `exit(0)` 来结束程序。

不过，这里可以看一下 `cgprintint()`：

```c
void cgprintint(int r) {
  fprintf(Outfile, "\tmovq\t%s, %%rdi\n", reglist[r]);
  fprintf(Outfile, "\tcall\tprintint\n");
  free_register(r);
}
```

Linux x86-64 要求函数的第一个参数放在 `%rdi` 寄存器里，
因此我们在 `call printint` 之前，
先把自己的寄存器内容移动到 `%rdi` 中。

## 完成第一次真正的编译

x86-64 代码生成器大致就是这些了。
`main()` 里还有一点额外代码，会把 `out.s` 打开成输出文件。
我也暂时把解释器保留在程序里，
这样就能确认生成的汇编代码是否和解释器算出了同样的结果。

下面我们构建编译器，并让它处理 `input01`：

```make
$ make
cc -o comp1 -g cg.c expr.c gen.c interp.c main.c scan.c tree.c

$ make test
./comp1 input01
15
cc -o out out.s
./out
15
```

对了！第一个 `15` 是解释器的输出，
第二个 `15` 是汇编程序运行后的输出。

## 看看生成出来的汇编代码

那么，实际生成出来的汇编代码到底长什么样？
先看输入文件：

```
2 + 3 * 5 - 8 / 3
```

下面是针对这个输入生成出来的 `out.s`，并附带注释：

```
        .text                           # Preamble code
.LC0:
        .string "%d\n"                  # "%d\n" for printf()
printint:
        pushq   %rbp
        movq    %rsp, %rbp              # Set the frame pointer
        subq    $16, %rsp
        movl    %edi, -4(%rbp)
        movl    -4(%rbp), %eax          # Get the printint() argument
        movl    %eax, %esi
        leaq    .LC0(%rip), %rdi        # Get the pointer to "%d\n"
        movl    $0, %eax
        call    printf@PLT              # Call printf()
        nop
        leave                           # and return
        ret

        .globl  main
        .type   main, @function
main:
        pushq   %rbp
        movq    %rsp, %rbp              # Set the frame pointer
                                        # End of preamble code

        movq    $2, %r8                 # %r8 = 2
        movq    $3, %r9                 # %r9 = 3
        movq    $5, %r10                # %r10 = 5
        imulq   %r9, %r10               # %r10 = 3 * 5 = 15
        addq    %r8, %r10               # %r10 = 2 + 15 = 17
                                        # %r8 and %r9 are now free again
        movq    $8, %r8                 # %r8 = 8
        movq    $3, %r9                 # %r9 = 3
        movq    %r8,%rax
        cqo                             # Load dividend %rax with 8
        idivq   %r9                     # Divide by 3
        movq    %rax,%r8                # Store quotient in %r8, i.e. 2
        subq    %r8, %r10               # %r10 = 17 - 2 = 15
        movq    %r10, %rdi              # Copy 15 into %rdi in preparation
        call    printint                # to call printint()

        movl    $0, %eax                # Postamble: call exit(0)
        popq    %rbp
        ret
```

很好！我们现在已经拥有了一个真正意义上的编译器：
它接受一种语言作为输入，再生成这段输入在另一种语言中的翻译结果。

当然，我们还得进一步把这些汇编输出汇编成机器码，
并和支持库链接起来，
但目前这部分我们暂时可以手工完成。
后面我们会再写代码把这一步自动化。

## 总结与下一步

从解释器切换到通用代码生成器本身很简单，
但接下来我们确实花了不少心思去生成真实的汇编输出。
为此，我们必须考虑如何分配寄存器；
而目前的方案还只是一个比较天真的版本。
同时，我们还得处理 x86-64 上一些比较别扭的地方，
比如 `idivq` 指令。

还有一个问题我暂时还没展开：为什么非得先为表达式构建 AST？
我们完全可以在 Pratt parser 中遇到 `+` token 时直接调用 `cgadd()`，
其他运算符也照此办理，不是吗？
这个问题我先留给你自己想一想，
不过在接下来的一两步里我还会回到它。

在编译器编写之旅的下一部分中，我们要给语言加入一些语句（statement），
让它开始更像一门真正的编程语言。 [下一步](../05_Statements/Readme.md)
