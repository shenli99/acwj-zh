# 第 37 部分：`switch` 语句

在编译器编写之旅的这一部分里，
我们要实现 `switch` 语句。
这件事之所以棘手，
有好几个原因，
我会逐步展开说明。
所以还是先从一个例子开始，
看看这里面到底牵扯到哪些影响。

## 一个 `switch` 语句示例

```c
  switch(x) {
    case 1:  printf("One\n");  break;
    case 2:  printf("Two\n");  break;
    case 3:  printf("Three\n");
    default: printf("More than two\n");
  }
```

它有点像一个“多路分支版的 `if` 语句”：
由 `x` 的值来决定执行哪一条分支。
不过这里必须插入 `break` 语句，
用来跳过后续所有其它分支；
如果你省掉 `break`，
那么当前分支执行完之后，
流程就会继续“贯穿（fall through）”
到下一条分支里。

`switch` 判定表达式必须是整数类型，
而所有 `case` 选项也都必须是整数字面量。
比如你不能写成 `case 3*y+17`。

`default` 分支会兜底匹配所有前面没有列出的值。
它必须出现在分支列表的最后。
另外我们也不能让 `case` 值重复，
所以像 `case 2: ...; case 2`
这样的写法是不允许的。

## 如何把上面的例子翻译成汇编

把 `switch` 翻译成汇编的一种方式，
就是把它当成“多路 `if`”来处理。
也就是说，
不断把 `x` 和各个整数值一一比较，
再根据比较结果进入或跳过对应的汇编代码块。
这样当然能工作，
但效率会比较糟，
尤其是像下面这种例子：

```c
  switch (2 * x - (18 +y)/z) { ... }
```

按照我们当前这个
遵循
[`KISS`](https://en.wikipedia.org/wiki/KISS_principle)
原则的编译器实现方式，
如果走“多路 `if`”那条路，
就不得不为每一次与字面量的比较
重复计算这整个表达式。

更合理的方式是：
先把 `switch` 表达式求值一次，
再拿这个值去和一张由 `case` 字面量构成的表逐项比较。
一旦匹配成功，
就跳到对应 `case` 的代码分支。
这就是所谓的
[跳转表（jump table）](https://en.wikipedia.org/wiki/Branch_table)。

这意味着，
每一个 `case` 选项
都必须拥有一个专属标签，
放在该选项代码的开头。
以前面的例子来说，
跳转表大概会像这样：

| Case Value | Label |
|:----------:|:-----:|
|     1      |  L18  |
|     2      |  L19  |
|     3      |  L22  |
|  default   |  L26  |

我们还需要一个标签，
用来标记整个 `switch` 语句之后的位置。
这样某个分支里如果执行了 `break;`，
就可以直接跳到这个 “switch 结束标签”。
否则，
就让当前分支自然落入下一个分支。

## 解析层面的影响

上面这些思路看起来都不错，
但解析时会碰到一个现实问题：
我们必须从上到下解析整个 `switch` 语句。
这意味着，
只有把所有 `case` 都读完之后，
我们才知道跳转表到底该有多大。
这也意味着，
除非我们耍一些比较聪明的技巧，
否则在能够生成跳转表之前，
我们已经先把各个 `case` 的汇编代码都生成出来了。

你也知道，
我写这个编译器一直遵循的是 “KISS principle”：
keep it simple, stupid！
所以我会尽量避开那些花哨技巧。
代价就是：
没错，
我们会把跳转表的输出推迟到
所有分支汇编代码都生成完之后。

从视觉上看，
我们的代码布局会像这样：

![](Figs/switch_logic.png)

最上面是计算 `switch` 判定值的代码，
因为解析时它最先出现。
但我们不希望执行流直接落进第一个 `case`，
所以会先跳到一个“稍后才输出”的标签。

然后，
我们逐个解析每个 `case`，
并生成对应的汇编代码。
由于 “switch 结束标签” 已经提前生成好了，
所以其中任何一段代码都可以跳到它那里去。
同样，
这个标签本身也是稍后才真正输出。

在为每个 `case` 生成代码时，
我们都会给它分配一个标签并立即输出该标签。
等到所有 `case` 和可能存在的 `default`
都输出完成之后，
就终于可以生成跳转表了。

但这时又冒出另一个问题：
我们还需要一段代码去遍历跳转表，
把 `switch` 的判定值和每个 `case` 值进行比较，
再跳到正确的位置。
当然可以为每一条 `switch` 语句
都单独生成这段汇编，
但如果这段“跳转处理逻辑”本身体积不小，
那就会很浪费内存。
更好的做法是：
内存里只放一份通用的跳转处理代码，
然后让不同的 `switch` 都跳过去复用它。

可问题又来了：
这段通用代码并不知道“当前的 `switch` 判定值”
放在哪个寄存器里。
因此，
我们还得先把这个值复制进一个约定好的寄存器，
再把跳转表基地址也复制进另一个约定好的寄存器。

我们实际上是在这里做了一次权衡：
把解析与代码生成的复杂度，
换成了一坨到处跳来跳去的“汇编意大利面”。
不过 CPU 倒是不在乎这些跳转意大利面，
所以目前来看这笔交易还算划算。
当然，
真正的生产级编译器大概率会采用不同做法。

图中的红线展示了执行流：
先计算 `switch` 判定值，
再把寄存器准备好，
进入跳转表处理逻辑，
最后跳到具体 `case` 的代码。
绿线表示：
跳转表的基地址会被传递给那段跳转处理代码。
最后，
蓝线表示某个 `case`
因为执行了 `break;`
而跳到了 `switch` 汇编代码的末尾。

所以整体来看，
汇编输出确实很丑，
但它是能工作的。
既然我们已经看清楚
`switch` 的实现路线，
那就正式动手吧。

## 新关键字与 token

为了支持新的 `case` 和 `default` 关键字，
我们新增了两个 token：`T_CASE` 和 `T_DEFAULT`。
具体代码照例自己去看实现。

## 新的 AST 节点类型

我们需要构建一棵 AST
来表示 `switch` 语句。
但 `switch` 语句的结构
显然不像普通表达式那样是一棵二叉树。
不过 AST 是我们自己的，
想怎么塑形都可以。
于是我坐下来想了一阵子，
最后决定采用下面这个结构：

![](Figs/switch_ast.png)

`switch` 语法树的根节点是 `A_SWITCH`。
左边子树保存“计算 `switch` 条件表达式”的那棵树。
右边则是一串由 `A_CASE` 组成的链表，
每个 `case` 一个节点。
最后，
还可以有一个可选的 `A_DEFAULT`
用来表示默认分支。

每个 `A_CASE` 节点中的 `intvalue` 字段，
保存的是该 `case` 的值，
也就是 `switch` 表达式必须匹配到的整数。
左子树则保存该 `case` 语句体的复合语句细节。
在这个阶段里，
我们还没有跳转标签，
也还没有跳转表；
这些都留到后面的代码生成阶段再说。

## 解析 `switch` 语句

到这里，
前置背景都铺好了，
终于可以来看 `switch` 语句本身的解析代码了。
这里面包含不少错误检查逻辑，
所以我会分小段来看。
代码位于 `stmt.c` 中，
并由 `single_statement()` 调用：

```c
    case T_SWITCH:
      return (switch_statement());
```

开始吧。

```c
// Parse a switch statement and return its AST
static struct ASTnode *switch_statement(void) {
  struct ASTnode *left, *n, *c, *casetree= NULL, *casetail;
  int inloop=1, casecount=0;
  int seendefault=0;
  int ASTop, casevalue;

  // Skip the 'switch' and '('
  scan(&Token);
  lparen();

  // Get the switch expression, the ')' and the '{'
  left= binexpr(0);
  rparen();
  lbrace();

  // Ensure that this is of int type
  if (!inttype(left->type))
    fatal("Switch expression is not of integer type");
```

可以看到，
开头这一堆局部变量已经在暗示：
这个函数里要维护不少状态。
不过第一段逻辑还算简单：
先解析 `switch (expression) {` 这个语法，
拿到表达式对应的 AST，
再检查它是否为整数类型。

```c
  // Build an A_SWITCH subtree with the expression as
  // the child
  n= mkastunary(A_SWITCH, 0, left, NULL, 0);

  // Now parse the cases
  Switchlevel++;
```

既然 `switch` 的条件表达式子树已经拿到，
我们就可以先构造一个 `A_SWITCH` 节点，
后面作为最终返回值。
你应该还记得，
之前我们只允许在“至少处于一层循环里”的情况下
出现 `break;`。
而现在，
只要处于某个 `switch` 语句内部，
`break;` 也应该被允许。
因此这里引入了一个新的全局变量 `Switchlevel`
来记录这一层上下文。

```c
  // Now parse the cases
  Switchlevel++;
  while (inloop) {
    switch(Token.token) {
      // Leave the loop when we hit a '}'
      case T_RBRACE: if (casecount==0)
                        fatal("No cases in switch");
                     inloop=0; break;
  ...
  }
```

这个循环由 `inloop` 控制，
它一开始是 1。
当我们遇到 `'}'` token 时，
就把它改成 0，
并跳出当前这个 `switch` 语句的解析循环。
同时还会检查：
我们至少已经看到过一个 `case`。

> 用一个 `switch` 语句去解析 `switch` 语句，
> 多少有点奇妙。

接下来就是 `case` 与 `default`
的具体解析逻辑：

```c
      case T_CASE:
      case T_DEFAULT:
        // Ensure this isn't after a previous 'default'
        if (seendefault)
          fatal("case or default after existing default");
```

这两个 token 共用同一段处理逻辑，
因为它们后续有很多共同步骤。
首先必须确保：
如果之前已经见过 `default`，
那后面就不能再出现新的 `case` 或 `default`，
因为 `default` 必须是最后一个分支。

```c
        // Set the AST operation. Scan the case value if required
        if (Token.token==T_DEFAULT) {
          ASTop= A_DEFAULT; seendefault= 1; scan(&Token);
        } else ...
```

如果当前正在解析 `default:`，
那它后面就没有整数字面量值。
因此只需要跳过这个关键字，
并记录“已经见过 default 分支”即可。

```c
        } else  {
          ASTop= A_CASE; scan(&Token);
          left= binexpr(0);
          // Ensure the case value is an integer literal
          if (left->op != A_INTLIT)
            fatal("Expecting integer literal for case value");
          casevalue= left->intvalue;

          // Walk the list of existing case values to ensure
          // that there isn't a duplicate case value
          for (c= casetree; c != NULL; c= c -> right)
            if (casevalue == c->intvalue)
              fatal("Duplicate case value");
        }
```

这段代码专门处理 `case <value>:`。
我们通过 `binexpr()` 读入 `case` 后面的值。
当然，
我本来也可以故作聪明地调用 `primary()`，
因为它更直接地针对整数字面量。
不过 `primary()` 自己最终也可能回到 `binexpr()`，
所以本质上没什么区别：
反正最后都还是要检查生成出来的树
是不是一个纯粹的 `A_INTLIT` 节点。

然后我们还得遍历前面已经构建好的 `A_CASE` 链表
（`casetree` 指向链表头），
确认当前这个 `case` 值没有重复。

与此同时，
我们也顺手把 `ASTop`
设成了 `A_CASE` 或 `A_DEFAULT`，
这样下一步就能进入两者共用的代码路径。

```c
        // Scan the ':' and get the compound expression
        match(T_COLON, ":");
        left= compound_statement(); casecount++;

        // Build a sub-tree with the compound statement as the left child
        // and link it in to the growing A_CASE tree
        if (casetree==NULL) {
          casetree= casetail= mkastunary(ASTop, 0, left, NULL, casevalue);
        } else {
          casetail->right= mkastunary(ASTop, 0, left, NULL, casevalue);
          casetail= casetail->right;
        }
        break;
```

这里先确认下一个 token 确实是 `':'`，
然后解析它后面的复合语句 AST。
接着用这个复合语句子树
作为左子节点，
构造一个 `A_CASE` 或 `A_DEFAULT` 节点，
并把它接到不断增长的
`A_CASE` / `A_DEFAULT` 链表后面：
`casetree` 是链表头，
`casetail` 是链表尾。

```c
      default:
        fatald("Unexpected token in switch", Token.token);
    }
  }
```

按理说，
`switch` 语句体里只应该出现
`case` 和 `default` 关键字，
因此这里要强制检查这一点。

```c
  Switchlevel--;

  // We have a sub-tree with the cases and any default. Put the
  // case count into the A_SWITCH node and attach the case tree.
  n->intvalue= casecount;
  n->right= casetree;
  rbrace();

  return(n);
```

终于，
所有 `case` 和可能存在的 `default`
都解析完了。
现在我们既拿到了它们的总数，
也拿到了由 `casetree` 指向的那条链表。
把这些信息挂回 `A_SWITCH` 节点上，
然后返回这棵完整的语法树即可。

好，
这一大段解析工作总算结束。
接下来该把注意力转到代码生成上了。

## `switch` 代码生成：先看一个例子

在这个阶段，
我觉得先看看一个 `switch` 示例生成出来的汇编会更有帮助。
这样你就能把代码结构
和我在开头给出的那张执行流程图对应起来。
例子如下：

```c
#include <stdio.h>

int x; int y;

int main() {
  switch(x) {
    case 1:  { y= 5; break; }
    case 2:  { y= 7; break; }
    case 3:  { y= 9; }
    default: { y= 100; }
  }
  return(0);
}
```

首先说明一下：
没错，
这里的 `case` 语句体依然得用 `'{ ... }'` 包起来。
因为我还没解决 “dangling else” 问题，
所以所有复合语句目前都必须显式加花括号。

我暂时先把“跳转表处理逻辑”那部分汇编省略掉，
下面是这个例子剩余部分的汇编输出：

![](Figs/switch_logic2.png)

顶部那段代码会先把 `x` 载入某个寄存器，
然后向下跳过跳转表。
由于“跳转表处理代码”并不知道
这个值原本落在哪个寄存器里，
所以我们统一把它搬到 `%rax`；
而跳转表的基地址则统一放进 `%rdx`。

跳转表本身的结构如下：

 + 第一项是“带整型值的 case 数量”
 + 接下来是一组“值 / 标签”对，每个 case 一对
 + 最后一项是 default 分支的标签。如果没有 default，
   那这里就必须放 `switch` 结束标签，
   这样在没有任何 case 匹配时就直接什么都不做

那段跳转表处理代码
（我们很快就会看到）
会解释这张表，
然后跳到其中某个标签。
假设现在跳到了 `L11`，
也就是 `case 2:`。
那我们就执行该分支对应的代码。
由于这个分支里带有 `break;`，
所以会跳到 `L9`，
也就是整个 `switch` 语句结束的位置。

## 跳转表处理代码

你已经知道，
x86-64 汇编并不是我的强项。
所以这段跳转表处理代码
我是直接从 [SubC](http://www.t3x.org/subc/) 借来的。
我把它加进了 `cg.c` 里的 `cgpreamble()` 函数，
这样每个输出的汇编文件都会自动带上它。
下面是带注释的代码：

```
# internal switch(expr) routine
# %rsi = switch table, %rax = expr

switch:
        pushq   %rsi            # Save %rsi
        movq    %rdx,%rsi       # Base of jump table -> %rsi
        movq    %rax,%rbx       # Switch value -> %rbx
        cld                     # Clear direction flag
        lodsq                   # Load count of cases into %rcx,
        movq    %rax,%rcx       # incrementing %rsi in the process
next:
        lodsq                   # Get the case value into %rdx
        movq    %rax,%rdx
        lodsq                   # and the label address into %rax
        cmpq    %rdx,%rbx       # Does switch value matches the case?
        jnz     no              # No, jump over this code
        popq    %rsi            # Restore %rsi
        jmp     *%rax           # and jump to the chosen case
no:
        loop    next            # Loop for the number of cases
        lodsq                   # Out of loop, load default label address
        popq    %rsi            # Restore %rsi
        jmp     *%rax           # and jump to the default case
```

我们确实该感谢一下 Nils Holm 写出了这段代码，
因为如果让我自己从头推，
我多半是写不出来的。

现在终于可以看看，
前面那份汇编输出到底是怎样生成出来的了。
好在 `cg.c` 里已经有不少现成函数可以复用。

## 生成汇编代码

在 `gen.c` 的 `genAST()` 中，
靠近顶部的位置，
我们会识别 `A_SWITCH` 节点，
然后调用一个专门的函数来处理它以及它下面的整棵子树。

```c
    case A_SWITCH:
      return (genSWITCH(n));
```

下面就分阶段来看这个新函数：

```c
// Generate the code for a SWITCH statement
static int genSWITCH(struct ASTnode *n) {
  int *caseval, *caselabel;
  int Ljumptop, Lend;
  int i, reg, defaultlabel = 0, casecount = 0;
  struct ASTnode *c;

  // Create arrays for the case values and associated labels.
  // Ensure that we have at least one position in each array.
  caseval = (int *) malloc((n->intvalue + 1) * sizeof(int));
  caselabel = (int *) malloc((n->intvalue + 1) * sizeof(int));
```

这里要 `+1` 的原因是：
即便存在一个 `default` 分支，
它虽然没有 `case` 值，
但依然需要一个标签位置。

```c
  // Generate labels for the top of the jump table, and the
  // end of the switch statement. Set a default label for
  // the end of the switch, in case we don't have a default.
  Ljumptop = genlabel();
  Lend = genlabel();
  defaultlabel = Lend;
```

这些标签现在只是先生成出来，
还没有真正输出为汇编。
在还没遇到 `default` 分支之前，
我们先把 `defaultlabel`
默认设成 `Lend`。

```c
  // Output the code to calculate the switch condition
  reg = genAST(n->left, NOLABEL, NOLABEL, NOLABEL, 0);
  cgjump(Ljumptop);
  genfreeregs();
```

这里先输出“计算 `switch` 条件值”的代码，
随后跳到跳转表之后的那段处理逻辑，
哪怕那段汇编此刻还没真正输出也没关系。
与此同时，
我们也可以把寄存器全部释放掉。

```c
  // Walk the right-child linked list to
  // generate the code for each case
  for (i = 0, c = n->right; c != NULL; i++, c = c->right) {

    // Get a label for this case. Store it
    // and the case value in the arrays.
    // Record if it is the default case.
    caselabel[i] = genlabel();
    caseval[i] = c->intvalue;
    cglabel(caselabel[i]);
    if (c->op == A_DEFAULT)
      defaultlabel = caselabel[i];
    else
      casecount++;

    // Generate the case code. Pass in the end label for the breaks
    genAST(c->left, NOLABEL, NOLABEL, Lend, 0);
    genfreeregs();
  }
```

这段代码一边为每个 `case` 生成标签，
一边输出它的语句体汇编。
同时，
还会把 `case` 值和对应标签
保存到那两个数组里。
如果当前节点是 `A_DEFAULT`，
那就可以顺手把 `defaultlabel`
更新成正确的标签。

还要注意一点：
这里传给 `genAST()` 的是 `Lend`，
也就是整个 `switch` 代码之后的那个标签。
这样 `case` 语句体里的任何 `break;`
都可以直接跳出 `switch`。

```c
  // Ensure the last case jumps past the switch table
  cgjump(Lend);

  // Now output the switch table and the end label.
  cgswitch(reg, casecount, Ljumptop, caselabel, caseval, defaultlabel);
  cglabel(Lend);
  return (NOREG);
}
```

我们不能指望程序员
一定会给最后一个 `case`
写上 `break;`，
所以这里强制为最后一个分支
补上一条跳往 `switch` 末尾的跳转。

到这里，
我们手上已经有了：

 + 保存 `switch` 值的寄存器
 + `case` 值数组
 + `case` 标签数组
 + `case` 的数量
 + 一组有用的标签

接着把这些全部传给 `cg.c` 里的 `cgswitch()`，
除了前面从 SubC 借来的那段代码之外，
这基本就是本部分新增的全部汇编相关工作了。

## `cgswitch()`

在这里，
我们需要真正构建跳转表，
并把寄存器准备好，
然后跳进那段 `switch` 汇编处理逻辑。
再提醒一次，
跳转表结构如下：

 + 第一项是“带整型值的 case 数量”
 + 接下来是一组“值 / 标签”对，每个 case 一对
 + 最后一项是 default 分支标签。如果没有 default，
   那这里就必须是 `switch` 结束标签，
   这样在没有任何匹配时就直接不执行任何分支

以前面的例子来说，
跳转表会像这样：

```
L14:                                    # Switch jump table
        .quad   3                       # Three case values
        .quad   1, L10                  # case 1: jump to L10
        .quad   2, L11                  # case 2: jump to L11
        .quad   3, L12                  # case 3: jump to L12
        .quad   L13                     # default: jump to L13
```

下面就是生成它的代码：


```c
// Generate a switch jump table and the code to
// load the registers and call the switch() code
void cgswitch(int reg, int casecount, int toplabel,
              int *caselabel, int *caseval, int defaultlabel) {
  int i, label;

  // Get a label for the switch table
  label = genlabel();
  cglabel(label);
```

这就是上面的 `L14:`。

```c
  // Heuristic. If we have no cases, create one case
  // which points to the default case
  if (casecount == 0) {
    caseval[0] = 0;
    caselabel[0] = defaultlabel;
    casecount = 1;
  }
```

跳转表里至少必须有一组“值 / 标签”对。
所以这里用了一个小技巧：
如果根本没有普通 `case`，
那就人工造出一条，
直接指向 `default` 分支。
这里的 `case` 值本身其实无所谓：
即使它匹配了也没关系；
如果不匹配，
反正最后还是会跳到 `default`。

```c
  // Generate the switch jump table.
  fprintf(Outfile, "\t.quad\t%d\n", casecount);
  for (i = 0; i < casecount; i++)
    fprintf(Outfile, "\t.quad\t%d, L%d\n", caseval[i], caselabel[i]);
  fprintf(Outfile, "\t.quad\tL%d\n", defaultlabel);
```

这段代码就是用来真正输出跳转表的。
很直白，
也很清爽。

```c
  // Load the specific registers
  cglabel(toplabel);
  fprintf(Outfile, "\tmovq\t%s, %%rax\n", reglist[reg]);
  fprintf(Outfile, "\tleaq\tL%d(%%rip), %%rdx\n", label);
  fprintf(Outfile, "\tjmp\tswitch\n");
}
```

最后，
把 `switch` 的值装入 `%rax`，
再把跳转表标签地址装入 `%rdx`，
然后跳到那段 `switch` 处理代码即可。

## 测试代码

我把前面的例子又包了一层循环，
这样 `switch` 里的所有分支都能被实际测试到。
测试文件是 `tests/input74.c`：

```c
#include <stdio.h>

int main() {
  int x;
  int y;
  y= 0;

  for (x=0; x < 5; x++) {
    switch(x) {
      case 1:  { y= 5; break; }
      case 2:  { y= 7; break; }
      case 3:  { y= 9; }
      default: { y= 100; }
    }
    printf("%d\n", y);
  }
  return(0);
}
```

程序输出如下：

```
100
5
7
100
100
```

注意并没有输出 9，
因为执行到 `case 3` 时，
流程会继续落入 `default` 分支。

## 总结与下一步

我们刚刚实现了编译器里的第一个真正意义上“体量很大”的新语句：
`switch`。
由于我自己之前也没实现过这玩意，
所以基本上是沿着 SubC 的做法一路跟下来的。
当然，
实现 `switch` 还有很多其它方式，
也可能更高效；
但我在这里还是坚持了 “KISS principle”。
即便如此，
这部分实现依旧相当复杂。

如果你读到这里还没退出，
那我得恭喜一下你的耐力。

我现在已经开始有点受不了
我们所有复合语句都必须强制写 `'{ ... }'`
这件事了。
所以在下一部分的编译器编写之旅里，
我会硬着头皮去尝试解决
“dangling else” 问题。 [下一步](../38_Dangling_Else/Readme.md)
