# 第 49 部分：三元运算符

在编译器编写之旅的这一部分里，
我实现了
[三元运算符（ternary operator）](https://en.wikipedia.org/wiki/%3F:)。
这是 C 语言里那种相当灵巧的运算符之一，
用得好时能让源码少写几行。
它的基本语法是：

```
ternary_expression:
        logical_expression '?' true_expression ':' false_expression
        ;
```

先对逻辑表达式求值。
如果结果为真，
那就只计算真分支表达式；
否则，
就只计算假分支表达式。
而最终，
无论是哪一个分支的值，
都会成为整个表达式的结果。

这里有个细节值得注意。
例如下面这句：

```c
   x= y != 5 ? y++ : ++y;
```

如果 `y != 5`，
那它就等价于 `x= y++`；
否则就等价于 `x= ++y`。
不管走哪边，
`y` 都只会被递增一次。

我们当然可以把它改写成 `if` 语句：

```c
if (y != 5)
  x= y++;
else
  x= ++y;
```

不过三元运算符本质上是一个表达式，
所以我们还能这样写：

```c
  x= 23 * (y != 5 ? y++ : ++y) - 18;
```

这时就很难直接把它改写成 `if` 语句了。
不过，
我们仍然可以借用 `if`
代码生成器里的部分机制，
来实现三元运算符。

## Token、运算符与优先级

在现有语法里，
我们已经有 `':'` 这个 token 了；
现在只需要再补上 `'?'`。
而既然要把它当成运算符，
那就必须给它分配优先级。

根据
[这份 C 运算符列表](https://en.cppreference.com/w/c/language/operator_precedence)，
`'?'` 的优先级
刚好位于赋值运算符之上。

而按照我们当前的设计，
运算符 token 必须按优先级顺序排列，
同时 AST 运算符也必须和这些 token 一一对应。

所以现在在 `defs.h` 中，
我们有了：

```c
// Token types
enum {
  T_EOF,

  // Binary operators
  T_ASSIGN, T_ASPLUS, T_ASMINUS,
  T_ASSTAR, T_ASSLASH,
  T_QUESTION,                   // The '?' token
  ...
enum {
  A_ASSIGN = 1, A_ASPLUS, A_ASMINUS, A_ASSTAR, A_ASSLASH,
  A_TERNARY,                    // The ternary AST operator
  ...
```

而在 `expr.c` 中，
优先级表现在会是这样：

```c
static int OpPrec[] = {
  0, 10, 10,                    // T_EOF, T_ASSIGN, T_ASPLUS,
  10, 10, 10,                   // T_ASMINUS, T_ASSTAR, T_ASSLASH,
  15,                           // T_QUESTION
  ...
```

至于新增 `T_QUESTION`
在 `scan.c` 中的扫描逻辑，
照例我就不细贴了，
你自己翻代码就能看到。

## 解析三元运算符

虽然三元运算符并不是一个二元运算符，
但既然它有优先级，
那实现时仍然得把它塞进 `binexpr()`
和其它二元运算符一起处理。
代码如下：

```c
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  struct ASTnode *ltemp, ...

    switch (ASTop) {
    case A_TERNARY:
      // Ensure we have a ':' token, scan in the expression after it
      match(T_COLON, ":");
      ltemp= binexpr(0);

      // Build and return the AST for this statement. Use the middle
      // expression's type as the return type. XXX We should also
      // consider the third expression's type.
      return (mkastnode(A_TERNARY, right->type, left, right, ltemp, NULL, 0));
      ...
    }
    ...
}
```

当我们进入 `A_TERNARY` 这个分支时，
逻辑表达式对应的 AST
已经保存在 `left` 中，
真分支表达式保存在 `right` 中，
而且 `'?'` 这个 token
也已经被解析过了。
接下来我们还得继续解析 `':'`
以及后面的假分支表达式。

当三部分都齐了之后，
就可以构造一个新的 AST 节点
把它们挂起来。
这里有个问题是：
这个三元节点本身到底该是什么类型？
如你所见，
现在我只是简单地拿了中间那个表达式的类型。
更严谨的做法，
应该是比较真分支和假分支两边，
看哪边类型更宽，
再选择那个。
这个问题我先留着，
以后再回头补。

## 生成汇编代码时的难点

为三元运算符生成汇编，
和为 `if` 语句生成汇编非常像：
我们先计算一个逻辑表达式；
如果为真，
就执行一边；
如果为假，
就执行另一边。

所以这里同样需要一组标签，
也同样需要根据需要跳转到这些标签。

我其实一开始试过
直接去修改 `gen.c` 里的 `genIF()`，
让它同时兼顾 `if` 和三元运算符。
但最后发现，
单独再写一个函数反而更容易。

这里真正的一个小难点在于寄存器管理。
看下面这个例子：

```c
   x= (y > 4) ? 2 * y - 18 : y * z - 3 * a;
```

这里一共有三段表达式，
而在计算每一段时都需要分配寄存器。
当逻辑表达式算完，
并跳到对应分支之后，
我们可以把为了逻辑表达式分配的那些寄存器全部释放掉。

但对真假分支表达式来说，
我们只能释放掉“除了最终结果之外”的其它寄存器。
因为其中必须保留一个寄存器，
来保存该分支表达式的右值结果。

而麻烦在于：
我们事先并不知道这个结果到底会落在哪个寄存器里。
因为真假分支各自的运算数和运算符都不同，
用掉的寄存器数量不同，
最终留下结果的那个寄存器编号
也就可能不同。

但后续真正使用三元运算符结果的那段代码，
又必须明确知道“结果在什么寄存器里”。

所以我们得做三件事：

  + 在计算真假分支之前，先提前分配一个“固定用来保存结果”的寄存器；
  + 把真假分支各自计算出的结果都拷贝进这个寄存器；以及
  + 释放所有其它寄存器，只保留这个结果寄存器。

## 释放寄存器

我们原本已经有一个
用来释放所有寄存器的函数 `freeall_registers()`，
它原先不接收参数。
而我们的寄存器编号是从零开始递增的。
现在我把它改成接收一个参数，
表示“这个寄存器不要释放”。
如果我们确实想释放 *全部* 寄存器，
那就传入 `NOREG`，
它被定义成 `-1`：

```c
// Set all registers as available.
// But if reg is positive, don't free that one.
void freeall_registers(int keepreg) {
  int i;
  for (i = 0; i < NUMFREEREGS; i++)
    if (i != keepreg)
      freereg[i] = 1;
```

## 为三元运算符生成汇编

既然现在已经有了“保留一个寄存器”的能力，
那就来看三元运算符的代码生成。
在 `genAST()` 里，
我们现在会这样处理：

```c
  case A_TERNARY:
    return (gen_ternary(n));
```

下面把 `gen_ternary()` 分段看一下。

```c
// Generate code for a ternary expression
static int gen_ternary(struct ASTnode *n) {
  int Lfalse, Lend;
  int reg, expreg;

  // Generate two labels: one for the
  // false expression, and one for the
  // end of the overall expression
  Lfalse = genlabel();
  Lend = genlabel();

  // Generate the condition code followed
  // by a jump to the false label.
  genAST(n->left, Lfalse, NOLABEL, NOLABEL, n->op);
  genfreeregs(-1);
```

这一段几乎和 `if` 的代码生成完全一样。
我们把逻辑表达式子树、
假分支标签
以及 `A_TERNARY` 运算符
一起传给 `genAST()`。
这样 `genAST()`
在看到它时，
就会知道：
如果条件为假，
就该跳到这个标签。

```c
  // Get a register to hold the result of the two expressions
  reg = alloc_register();

  // Generate the true expression and the false label.
  // Move the expression result into the known register.
  expreg = genAST(n->mid, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  // Don't free the register holding the result, though!
  genfreeregs(reg);
  cgjump(Lend);
  cglabel(Lfalse);
```

逻辑表达式处理完之后，
我们先分配一个寄存器，
专门用来保存真假分支的最终结果。
然后调用 `genAST()` 去生成真分支表达式，
并拿到它真正落在哪个寄存器里。
接着把这个结果拷贝进我们预留好的那个“固定寄存器”。

做完之后，
就可以释放掉除该寄存器之外的所有寄存器。
如果刚才走的是真分支，
那接下来还得跳到三元运算符整体代码的末尾。

```c
  // Generate the false expression and the end label.
  // Move the expression result into the known register.
  expreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);
  cgmove(expreg, reg);
  // Don't free the register holding the result, though!
  genfreeregs(reg);
  cglabel(Lend);
  return (reg);
}
```

假分支这一边的处理方式完全类似。
不管最后走的是真分支还是假分支，
执行流最终都会来到 `Lend`。
而一旦到达这里，
我们就知道：
三元运算符的结果一定已经安稳地躺在那个固定寄存器里了。

## 测试新代码

我之前其实挺担心“嵌套三元运算符”的情况，
因为我在别的代码里用过不少。
三元运算符是
*右结合（right associative）* 的，
也就是说，
`'?'`
会更紧地和右边绑定。

不过幸运的是，
由于我们的解析器在读到 `'?'` 之后，
会贪婪地继续查找对应的 `':'`
以及后面的假分支表达式，
所以它本来就已经把三元运算符
当成右结合来处理了。

`tests/input121.c`
就是一个嵌套三元运算符的例子：

```c
#include <stdio.h>

int x;
int y= 3;

int main() {
  for (y= 0; y < 10; y++) {
    x= (y < 4) ? y + 2 :
       (y > 7) ? 1000 : y + 9;
    printf("%d\n", x);
  }
  return(0);
}
```

如果 `y < 4`，
那 `x` 就会变成 `y + 2`。
否则，
就继续去计算第二层三元运算符。
如果 `y > 7`，
那 `x` 就会变成 1000；
否则，
它就会变成 `y + 9`。

最终效果是：
当 `y` 为 0 到 3 时，
执行 `y + 2`；
当 `y` 为 4 到 7 时，
执行 `y + 9`；
再往上就是 1000：

```
2
3
4
5
13
14
15
16
1000
1000
```

## 总结与下一步

和之前一些阶段类似，
我本来也有点怕去碰三元运算符，
因为我以为它会很难。
我在尝试把它硬塞进 `if` 的代码生成逻辑时
确实遇到了一些麻烦，
所以后来干脆退后一步。
实际上，
我还和我妻子出去看了场电影，
这给了我一点时间慢慢想。
后来我意识到：
关键在于“释放除一个之外的所有寄存器”，
以及“应该单独写一个函数来处理它”。
把这点想通之后，
后面的代码其实就比较顺了。
有时候离开键盘一会儿，
确实很有帮助。

在编译器编写之旅的下一部分中，
我会继续把编译器源码喂给它自己，
看看会撞出哪些解析错误，
然后挑其中一个或几个来修。

> P.S. 我们已经走到 5,000 行代码，
Readme 也累计到 90,000 个词了。
应该快到了吧！ [下一步](../50_Mop_up_pt1/Readme.md)
