# 第 54 部分：寄存器溢出

我一直拖着没去处理
[寄存器溢出（register spilling）](https://en.wikipedia.org/wiki/Register_allocation#Spilling)
这个问题，
因为我知道它会相当棘手。
我这次做出来的东西，
更像是对这个问题的第一刀切入。
它很朴素，
甚至可以说有些笨，
但至少算是开了个头。

## 这里的问题

在大多数 CPU 里，
寄存器都是一种稀缺资源。
它们是速度最快的存储单元，
而我们会用它们来保存表达式求值过程中的临时结果。
一旦某个结果已经被写回到更持久的位置
（例如代表某个变量的内存地址），
我们就可以释放这些正在使用中的寄存器，
然后再次复用它们。

可一旦遇到复杂度较高的表达式，
我们就会没有足够多的寄存器
来保存中间结果，
从而导致整个表达式无法继续求值。

目前编译器最多只能分配四个寄存器。
是的，
我知道这多少有点人为设限；
不过不管怎样，
只要寄存器数量是固定的，
就总会存在某个足够复杂的表达式，
让它超出这个上限。

看下面这个表达式，
同时回忆一下 C 运算符的优先级：

```c
  int x= 5 || 6 && 7 | 8 & 9 << 2 + 3 * 4;
```

右侧每个运算符的优先级
都高于它左边那个运算符。
因此，
我们得先把 5 放进一个寄存器，
然后继续去计算剩下的表达式。
接着把 6 放进一个寄存器，
继续。
再把 7 放进一个寄存器，
继续。
再把 8 放进一个寄存器，
继续。

糟了！
现在我们还需要把 9 也装进寄存器，
但四个寄存器都已经被分配出去了。
事实上，
要算完这个表达式，
我们还得额外再拿出 *四个* 寄存器。
那该怎么办？

办法就是把某些寄存器
[溢出（spill）](https://en.wikipedia.org/wiki/Register_allocation#Spilling)
到主内存里的某个位置，
从而腾出寄存器。
不过事情并不只是“存出去”这么简单：
等我们后面还需要这个值时，
还得把它重新装回来。
而且重新装回来的那一刻，
目标寄存器还必须是空闲的，
这样才能恢复它原来的旧值。

所以，
我们不仅要有办法把寄存器溢出到某个地方，
还得追踪：
到底哪些寄存器被溢出了、
是在什么时候被溢出的、
以及何时应该把它们重新装回来。
这事并不轻松。
从上面的外部链接里你也能看出来，
围绕“最优寄存器分配与溢出”其实有一整套厚重理论。
这里不会展开那部分理论。
我会先实现一个简单方案，
如果你愿意，
以后完全可以基于那些理论把代码继续优化下去。

那么，
这些寄存器该溢出到哪里？
我们当然可以自己分配一块任意大小的
[内存堆（memory heap）](https://en.wikipedia.org/wiki/Memory_management#Dynamic_memory_allocation)，
然后把所有溢出的寄存器都存进去。
不过通常来说，
大多数寄存器溢出的实现
都会直接使用现有的栈（stack）。
为什么？

原因有几个：
我们已经有由硬件直接支持的 `push` 和 `pop`
栈操作，
速度很快；
通常还可以依赖操作系统按需扩展栈空间；
而且我们本来就会把栈划分成一个个栈帧（stack frame），
每个函数一个。
到了函数结束时，
我们只需要移动栈指针，
就不必担心那些被我们溢出到栈里、
又不小心忘记逐个弹出的寄存器值。

所以在我们的编译器里，
我准备使用栈来做寄存器溢出。
先来看看，
不管是“寄存器溢出”本身，
还是“借助栈来实现寄存器溢出”，
都会带来哪些影响。

## 这样做带来的影响

要实现寄存器溢出，
我们需要具备以下能力：

 + 当我们需要分配寄存器、
   但手头一个空闲寄存器都没有时，
   能够选择某个寄存器并把它的值溢出出去。
   具体做法就是把它压栈。
 + 当后面需要这个寄存器的值时，
   能够把它从栈上重新装回来。
 + 在需要重装这个值的时刻，
   保证对应寄存器是空闲的。
 + 在函数调用之前，
   我们需要把所有正在使用中的寄存器都先溢出。
   因为函数调用本身也是表达式的一部分。
   我们必须能正确处理
   `2 + 3 * fred(4,5) - 7`
   这种表达式，
   并且在函数返回之后，
   仍然保住寄存器里原先那 2 和 3 对应的值。
 + 因而，
   我们还得在函数调用结束之后，
   把那些之前溢出的寄存器全部重新装回来。

上面这些能力，
不管你最后采用什么具体机制，
都必须具备。
现在把“栈”拉进来，
看看它会怎样约束我们的实现。

如果我们只能通过“把寄存器压栈”来溢出，
又只能通过“把值从栈顶弹出”来恢复，
那就意味着：
我们必须严格按照和溢出相反的顺序来恢复寄存器。
我们能保证这一点吗？
换句话说，
会不会出现某种情况，
让我们不得不乱序地恢复某个寄存器？
如果会，
那栈就不是我们应该选择的机制。
或者反过来说，
我们能不能把编译器写成这样：
始终保证寄存器恢复顺序
就是溢出顺序的逆序？

## 一些可做的优化

如果你读过上面的外部链接，
或者本来就对寄存器分配有些了解，
那你大概知道：
在寄存器分配和寄存器溢出这件事上，
可优化的地方多得很。
你也许比我懂得多得多，
所以下一节如果写得很原始，
还请不要笑得太大声。

当我们调用一个函数时，
并不是所有寄存器都一定已经被占满。
此外，
其中有些寄存器
还会被拿去保存函数参数。
而函数本身很可能还会返回一个值，
从而破坏掉某个寄存器中的内容。
因此，
在函数调用之前，
我们其实并不一定非要把所有寄存器都压到栈上。
如果我们足够聪明，
就可以分析出：
到底哪些寄存器必须溢出，
然后只处理这些寄存器即可。

甚至，
我们还可以再往前走一步，
直接重写 AST 树本身，
从根源上减轻表达式求值时对寄存器的压力。
比如，
我们可以采用某种形式的
[强度削减（strength reduction）](https://en.wikipedia.org/wiki/Strength_reduction)，
来降低需要分配的寄存器数量。

看下面这个表达式：

```c
  2 + (3 + (4 + (5 + (6 + (7 + 8)))))
```

按它现在这个写法，
我们必须先把 2 装入寄存器，
然后开始计算后面的部分；
再把 3 装入寄存器，
再继续。
最终会分配出七个寄存器。

但加法是 *commutative*（可交换）的，
因此我们完全可以把上面的表达式
重新看成这样：

```c
  ((((2 + 3) + 4) + 5) + 6) + 7
```

这样一来，
我们先计算 `2+3`，
把结果放进一个寄存器，
然后再继续加上 `4`，
整个过程中仍然只需要一个寄存器，
以此类推。
这正是
[SubC](http://www.t3x.org/subc/)
编译器在处理 AST 树时会做的事情，
我之后也会把类似思路实现进来。

但现在先不做任何优化。
事实上，
接下来的这套寄存器溢出代码
会生成相当难看的汇编。
不过至少它能工作。
记住那句老话：
"*premature optimisation is the root of all evil*"
也就是 Donald Knuth 那句著名的话。

## 具体实现细节

先看 `cg.c` 里最基础的两个新函数：

```c
// Push and pop a register on/off the stack
static void pushreg(int r) {
  fprintf(Outfile, "\tpushq\t%s\n", reglist[r]);
}

static void popreg(int r) {
  fprintf(Outfile, "\tpopq\t%s\n", reglist[r]);
}
```

我们可以用它们
把寄存器值压到栈上，
或者再从栈里恢复出来。
注意，
我没有把它们命名成 `spillreg()` 和 `reloadreg()`。
因为它们是通用操作，
以后也许还会被拿去做别的事情。

## `spillreg`

接下来是在 `cg.c` 里新增的一个静态变量：

```c
static int spillreg=0;
```

它表示：
下一个将要被我们选中并溢出的寄存器编号。
每次溢出一个寄存器后，
我们都会把 `spillreg` 加一。
因此它最终会变成 4、
再变成 5、
再变成 8、
再变成 3002，
如此继续。

问题来了：
为什么不在它超过寄存器上限之后
直接把它重置回零？
原因在于：
当我们从栈里把寄存器值重新弹出来时，
必须知道“什么时候该停止继续弹”。
如果我们始终只是做模运算循环，
那我们就只会在固定的周期里不停转圈，
却不知道真正该在什么时候停下来。

当然，
我们实际能够拿来溢出的寄存器
仍然只限于 `0` 到 `NUMFREEREGS-1`。
因此在接下来的代码里，
我们还是会做一点模运算。

## 溢出一个寄存器

当没有空闲寄存器可分配时，
我们就要溢出一个寄存器。
被选中的寄存器会是
`spillreg` 对 `NUMFREEREGS` 取模之后的那个。
在 `cg.c` 的 `alloc_register()` 函数里：

```c
int alloc_register(void) {
  int reg;

  // Try to allocate a register but fail
  ...
  // We have no registers, so we must spill one
  reg= (spillreg % NUMFREEREGS);
  spillreg++;
  fprintf(Outfile, "# spilling reg %d\n", reg);
  pushreg(reg);
  return (reg);
}
```

我们通过 `spillreg % NUMFREEREGS`
选出要溢出的寄存器，
然后调用 `pushreg(reg)` 把它压栈。
接着把 `spillreg` 递增，
表示下次该轮到下一个寄存器被溢出。
最后把刚刚腾出来的这个寄存器号返回，
因为它现在已经重新可用了。
里面那条调试输出，
我之后会删掉。

## 重新装回一个寄存器

一个寄存器只有在两种条件都满足时，
才能被重新装回：
一是它此时已经空闲；
二是它正好是“最近一次被溢出到栈上的那个寄存器”。
这里其实就埋了一个隐含前提：
我们必须始终按“最近一次溢出的寄存器优先恢复”的方式来工作。
所以我们最好确保编译器真的能守住这个承诺。

`cg.c` 里 `free_register()` 的新代码如下：

```c
static void free_register(int reg) {
  ...
  // If this was a spilled register, get it back
  if (spillreg > 0) {
    spillreg--;
    reg= (spillreg % NUMFREEREGS);
    fprintf(Outfile, "# unspilling reg %d\n", reg);
    popreg(reg);
  } else        // Simply free the in-use register
  ...
}
```

我们只是简单地把最近一次的溢出撤销掉，
同时把 `spillreg` 减一。
也正因为如此，
我们前面才没有把 `spillreg`
直接存成模运算之后的值。
当它回到零时，
我们就知道：
栈上已经没有任何“等待恢复的寄存器”了，
也就没必要再尝试从栈里弹出寄存器值。

## 函数调用前的寄存器溢出

前面提到过：
一个足够聪明的编译器，
应该能够判断“函数调用前到底哪些寄存器 *必须* 先溢出”。
但这不是一个聪明的编译器，
所以我们现在新增了下面这些函数：

```c
// Spill all registers on the stack
void spill_all_regs(void) {
  int i;

  for (i = 0; i < NUMFREEREGS; i++)
    pushreg(i);
}

// Unspill all registers from the stack
static void unspill_all_regs(void) {
  int i;

  for (i = NUMFREEREGS-1; i >= 0; i--)
    popreg(i);
}
```

如果你此时正在边看边笑，
或者边看边哭，
又或者两者都有，
那我就顺手提醒你一句 Ken Thompson 的名言：
"*When in doubt, use brute force.*"

## 保住我们的隐含假设

这套代码里有一个隐含前提：
任何被重新装回的寄存器，
都必须是“最后一个被溢出的寄存器”。
我们最好验证一下，
事情确实会按这个规则发生。

对于二元表达式，
`gen.c` 里的 `genAST()` 会这样做：

```c
  // Get the left and right sub-tree values
  leftreg = genAST(n->left, NOLABEL, NOLABEL, NOLABEL, n->op);
  rightreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);

  switch (n->op) {
    // Do the specific binary operation
  }
```

我们会先为左侧表达式分配寄存器，
再为右侧表达式分配寄存器。
如果这期间不得不发生寄存器溢出，
那么“右侧表达式所对应的寄存器”
就会是最近一次被溢出的那个寄存器。

因此，
我们最好也 *先释放* 右侧表达式的那个寄存器，
这样一来，
若它之前确实是通过溢出腾出来的，
它原本保存的旧值
就能被正确地恢复回这个寄存器中。

我已经把 `cg.c` 里那些二元表达式生成器
大致都按这个思路改过一遍。
例如 `cg.c` 里的 `cgadd()`：

```c
// Add two registers together and return
// the number of the register with the result
int cgadd(int r1, int r2) {
  fprintf(Outfile, "\taddq\t%s, %s\n", reglist[r2], reglist[r1]);
  free_register(r2);
  return (r1);
}
```

过去的实现会把结果加到 `r2` 里，
释放 `r1`，
最后返回 `r2`。
这可不行。
不过幸运的是加法是可交换的，
所以结果放在任一寄存器都可以。
现在结果保存在 `r1`，
而 `r2` 被释放。
如果 `r2` 之前是被溢出后才临时空出来的，
那它原来的值也会随之被正确恢复。

我 *希望* 自己已经把所有该改的地方都改到了，
也 *希望* 我们这个隐含假设始终成立，
但我现在还不能百分之百确定。
接下来还得做大量测试，
才敢说基本放心。

## 对函数调用的修改

现在，
普通寄存器分配与释放所需要的
溢出/恢复基础设施已经都有了。
对一般的寄存器分配与释放来说，
上面的代码会在必要时自动做寄存器溢出与恢复。
同时我们也尽量保证：
总是优先释放最近一次溢出所对应的寄存器。

接下来最后还要做的一件事，
就是在函数调用前溢出寄存器，
并在函数调用后把它们恢复回来。
这里还有一个小弯子：
函数调用本身可能嵌在某个更大的表达式里。
因此我们需要：

  1. 先把寄存器溢出出去。
  1. 把函数参数拷贝过去
     （这个过程也会使用寄存器）。
  1. 调用函数。
  1. 在继续后续处理之前先恢复寄存器。
  1. 再拷贝函数返回值所在的寄存器。

后面两步如果顺序做反了，
我们在恢复那些旧寄存器时
就会把函数刚返回出来的值给覆盖掉。

为了实现上面的流程，
我不得不把“溢出/恢复”的职责
拆给 `gen.c` 和 `cg.c` 两边协作完成。

在 `gen.c` 的 `gen_funccall()` 里：

```c
static int gen_funccall(struct ASTnode *n) {
  ...

  // Save the registers before we copy the arguments
  spill_all_regs();

  // Walk the list of arguments and copy them
  ...
  // Call the function, clean up the stack (based on numargs),
  // and return its result
  return (cgcall(n->sym, numargs));
}
```

它负责第 1、2、3 步：
溢出、拷贝参数、调用函数。
而在 `cg.c` 的 `cgcall()` 里：

```c
int cgcall(struct symtable *sym, int numargs) {
  int outr;

  // Call the function
  ...
  // Remove any arguments pushed on the stack
  ...

  // Unspill all the registers
  unspill_all_regs();

  // Get a new register and copy the return value into it
  outr = alloc_register();
  fprintf(Outfile, "\tmovq\t%%rax, %s\n", reglist[outr]);
  return (outr);
}
```

它负责最后两步：
先恢复寄存器，
再把返回值拷到一个新分配的寄存器里。

## 来看例子

下面是一些会触发寄存器溢出的例子：
函数调用，
以及复杂表达式。
先看 `tests/input136.c`：

```c
int add(int x, int y) {
  return(x+y);
}

int main() {
  int result;
  result= 3 * add(2,3) - 5 * add(4,6);
  printf("%d\n", result);
  return(0);
}
```

`add()`
必须被当成表达式来处理。
我们先把 3 放进一个寄存器，
然后在调用 `add(2,3)` 之前
把所有寄存器都溢出到栈上。
恢复这些寄存器之后，
再去读取函数返回值。
对应生成的汇编如下：

```
        movq    $3, %r10        # Get 3 into %r10
        pushq   %r10
        pushq   %r11            # Spill all four registers, thus
        pushq   %r12            # preserving the %r10 value
        pushq   %r13
        movq    $3, %r11        # Copy the 3 and 2 arguments
        movq    %r11, %rsi
        movq    $2, %r11
        movq    %r11, %rdi
        call    add@PLT         # Call add()
        popq    %r13
        popq    %r12            # Reload all four registers, thus
        popq    %r11            # restoring the %r10 value
        popq    %r10
        movq    %rax, %r11      # Get the return value into %r11
        imulq   %r11, %r10      # Multiply 3 * add(2,3)
```

没错，
这里的优化空间还很大。
不过先遵循 KISS 原则吧。

在 `tests/input137.c` 里，
还有这样一个表达式：

```c
  x= a + (b + (c + (d + (e + (f + (g + h))))));
```

它总共需要八个寄存器，
因此我们不得不额外溢出其中四个。
生成的汇编如下：

```
        movslq  a(%rip), %r10
        movslq  b(%rip), %r11
        movslq  c(%rip), %r12
        movslq  d(%rip), %r13
        pushq   %r10             # spilling %r10
        movslq  e(%rip), %r10
        pushq   %r11             # spilling %r11
        movslq  f(%rip), %r11
        pushq   %r12             # spilling %r12
        movslq  g(%rip), %r12
        pushq   %r13             # spilling %r13
        movslq  h(%rip), %r13
        addq    %r13, %r12
        popq    %r13            # unspilling %r13
        addq    %r12, %r11
        popq    %r12            # unspilling %r12
        addq    %r11, %r10
        popq    %r11            # unspilling %r11
        addq    %r10, %r13
        popq    %r10            # unspilling %r10
        addq    %r13, %r12
        addq    %r12, %r11
        addq    %r11, %r10
        movl    %r10d, -4(%rbp)
```

总之，
它最终能够正确地完成这个表达式的求值。

## 总结与下一步

寄存器分配和寄存器溢出
都是很难彻底做对的东西，
而且背后还可以引入大量优化理论。
我这次实现的寄存器分配与寄存器溢出方案
相当朴素。
它能工作，
但仍然有很大的提升空间。

在做上面这些工作的同时，
我也顺手修好了 `&&` 和 `||` 的问题。
不过我决定把这一部分内容
放到下一章单独来写，
尽管这一章对应的代码里其实已经包含了那些改动。 [下一步](../55_Lazy_Evaluation/Readme.md)
