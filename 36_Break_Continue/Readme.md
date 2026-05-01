# 第 36 部分：`break` 与 `continue`

前一阵子，
我曾经给一个无类型语言写过另一个
[简单编译器](https://github.com/DoctorWkt/h-compiler)，
当时并没有使用抽象语法树（AST）。
这让给语言加入 `break` 和 `continue` 关键字
变得相当别扭。

而在这里，
我们确实为每个函数都构建了一棵 AST。
这让实现 `break` 和 `continue`
容易了许多。
下面我会说明原因。

## 加入 `break` 与 `continue`

不出意外，
我们又新增了两个 token：`T_BREAK` 和 `T_CONTINUE`，
同时 `scan.c` 中的扫描器代码
也已经能识别 `break` 与 `continue` 关键字。
具体做法照例直接去看代码就行。

## 新的 AST 节点类型

我们还在 `defs.h` 中加入了两个新的 AST 节点类型：
`A_BREAK` 和 `A_CONTINUE`。
当我们解析到 `break` 关键字时，
就可以生成一个 `A_BREAK` AST 叶子节点；
同理，
`continue` 会生成一个 `A_CONTINUE` 叶子节点。

接下来，
当我们遍历 AST 并生成汇编代码时，
一旦遇到 `A_BREAK` 节点，
就需要生成一条汇编跳转，
跳到“当前所在循环”的末尾标签。
而如果遇到 `A_CONTINUE`，
就跳到“重新判断循环条件之前”的那个标签。

问题来了：
我们怎么知道自己当前处在哪一层循环里？

## 跟踪最近一层循环

循环可以嵌套，
所以在任意时刻都可能有多组循环标签同时存在。
这正是我之前写上一个编译器时
觉得最棘手的地方。
而现在既然我们有一棵可以递归遍历的 AST，
那就可以把“最近一层循环的标签信息”
一路向下传给子节点。

其实我们已经在做类似的事了，
比如为 `if` 或 `while` 语句生成代码时，
都需要知道该跳往哪里。
下面是 `gen.c` 中为 `if` 生成汇编的一部分代码：

```c
// Generate the code for an IF statement
// and an optional ELSE clause
static int genIF(struct ASTnode *n) {
  int Lfalse, Lend;

  // Generate two labels: one for the
  // false compound statement, and one
  // for the end of the overall IF statement.
  Lfalse = genlabel();
  Lend = genlabel();

  // Generate the condition code followed
  // by a jump to the false label.
  genAST(n->left, Lfalse, n->op);
```

左子树负责计算 `if` 条件，
所以它必须拿到我们刚生成的那个标签。
因此在调用 `genAST()` 生成这个子节点的汇编输出时，
我们也会把标签信息一起传进去。

而对循环来说，
我们需要传给 `genAST()` 的，
除了循环末尾标签以外，
还要有“判断循环条件之前”的那个标签。
因此我修改了 `genAST()` 的接口：

```c
int genAST(struct ASTnode *n, int iflabel, int looptoplabel,
           int loopendlabel, int parentASTop);
```

我们保留原有的 `iflabel`，
同时再补上两个循环相关标签。
这样一来，
就必须把每个循环生成出来的标签
继续传给 `genAST()`。
所以在生成 `while` 循环代码时，
就会变成这样：

```c
static int genWHILE(struct ASTnode *n) {
  int Lstart, Lend;

  // Generate the start and end labels
  Lstart = genlabel();
  Lend = genlabel();

  // Generate the condition code followed
  // by a jump to the end label.
  genAST(n->left, Lend, Lstart, Lend, n->op);

  // Generate the compound statement for the body
  genAST(n->right, NOLABEL, Lstart, Lend, n->op);
  ...
}
```

## `genAST()` 是递归的

那嵌套循环怎么办？
来看下面这段代码：

```
L1:
  while (x < 10) {
    if (x == 6) break;
L2:
    while (y < 10) {
      if (y == 6) break;
      y++;
    }
L3:
    x++;
  }
L4:
```

这里的 `if (y == 6) break`
应该跳出内层循环，
并跳到 `x++` 那段代码，
也就是 `L3`；
而 `if (x == 6) break;`
则应该跳出外层循环，
跳到标签 `L4`。

之所以能做到这一点，
是因为 `genAST()` 在处理外层循环时会调用 `genWHILE()`。
后者再调用 `genAST(L1, L4)`，
于是第一个 `break`
看到的就是这组循环标签。
随后当代码走到第二层循环时，
又会再次调用 `genWHILE()`。
它会生成新的一组循环标签，
并调用 `genAST(L2, L3)` 来生成内层循环代码。
于是第二个 `break`
看到的是 `L2` 和 `L3`，
而不是 `L1` 与 `L4`。

最后，
当内层复合语句生成完成后，
内部那次 `genAST()` 返回，
流程又回到外层那套带有 `L1` 和 `L4` 标签的上下文。

## 上述设计带来的实现含义

这在实现上的含义就是：
凡是会调用 `genAST()` 的地方
（包括 `genAST()` 自己递归调用自己时），
只要当前上下文有可能处在某个循环里，
那就必须把当前循环标签继续往下传。

前面我们已经看过 `genWHILE()`
如何把新的循环标签传给 `genAST()`。
现在再看看还有哪些地方也必须传播这些标签。

当我第一次实现 `break` 时，
写了下面这个测试程序：

```c
int main() {
  int x;
  x = 0;
  while (x < 100) {
    printf("%d\n", x);
    if (x == 14) { break; }
    x = x + 1;
  }
  printf("Done\n");
```

然后我看了一眼生成出来的汇编，
发现 `break`
竟然被翻译成了跳往标签 `L0`。
也就是说，
循环末尾标签根本没有传到处理 `break` 的那段代码里。
我沿着编译器的调用栈一查，
发现流程是这样的：

  + 函数级别的 `genAST()` 调用了
  + 负责循环的 `genWHILE()`，它生成标签并把它们传给了
  + 处理循环体的 `genAST()`，而它又调用了
  + `genIF()`，但这里并没有继续把任何标签传给
  + 用来生成 `if` 语句体的 `genAST()`。于是 `break` 根本看不到标签。

所以我还得顺手修改 `genIF()` 的参数列表：

```c
static int genIF(struct ASTnode *n, int looptoplabel, int loopendlabel);
```

我就不把 `gen.c` 里所有相关代码一段段贴出来了；
你直接打开文件，
搜一遍所有对 `genAST()` 的调用，
就能看到这些循环标签到底是怎样一路向下传递的。

最后，
我们当然还得真正为 `break` 和 `continue`
生成汇编代码。
下面就是 `gen.c` 里 `genAST()` 中对应的实现：

```c
    case A_BREAK:
      cgjump(loopendlabel);
      return (NOREG);
    case A_CONTINUE:
      cgjump(looptoplabel);
      return (NOREG);
```

## 解析 `break` 与 `continue`

这次我先讲了代码生成，
再回过头来说解析流程。
现在该轮到这两个新关键字的解析了。
好在它们的语法非常简单：
要么是 `break ;`，
要么是 `continue ;`。
看起来应该很好处理。
当然，
其中还是有个小小的弯。

我们是在 `stmt.c` 的 `single_statement()`
里解析单条语句的，
所以改动很小：

```c
    case T_BREAK:
      return (break_statement());
    case T_CONTINUE:
      return (continue_statement());
```

另外还得在 `compound_statement()` 中做一点小修改，
确保这些语句后面跟着分号：

```c
compound_statement(void) {
  struct ASTnode *left = NULL;
  struct ASTnode *tree;

  ...
  while (1) {
    // Parse a single statement
    tree = single_statement();

    // Some statements must be followed by a semicolon
    if (tree != NULL && (tree->op == A_ASSIGN || tree->op == A_RETURN
                         || tree->op == A_FUNCCALL || tree->op == A_BREAK
                         || tree->op == A_CONTINUE))
      semi();
    ...
}
```

现在来说那个小弯。
下面这段程序其实是非法的：

```c
int main() {
  break;
}
```

因为这里根本没有任何循环可以跳出。
所以我们必须跟踪“当前正在解析的循环深度”，
只有深度不为零时，
才允许出现 `break` 或 `continue`。
因此这两个关键字的解析函数会写成这样：

```c
// Parse a break statement and return its AST
static struct ASTnode *break_statement(void) {

  if (Looplevel == 0)
    fatal("no loop to break out from");
  scan(&Token);
  return (mkastleaf(A_BREAK, 0, NULL, 0));
}

// continue_statement: 'continue' ;
//
// Parse a continue statement and return its AST
static struct ASTnode *continue_statement(void) {

  if (Looplevel == 0)
    fatal("no loop to continue to");
  scan(&Token);
  return (mkastleaf(A_CONTINUE, 0, NULL, 0));
}
```

## 循环层级

我们需要一个 `Looplevel` 变量
来记录当前正在解析的循环嵌套层数。
它定义在 `data.h` 中：

```c
extern_ int Looplevel;                  // Depth of nested loops
```

接下来就得在合适的地方维护这个层级。
每当我们开始解析一个新函数时，
层级都会被重置为零
（代码在 `decl.c` 中）：

```c
// Parse the declaration of function.
struct ASTnode *function_declaration(int type) {
  ...
  // Get the AST tree for the compound statement and mark
  // that we have parsed no loops yet
  Looplevel= 0;
  tree = compound_statement();
  ...
}
```

而每当解析到一个循环时，
就要在解析循环体之前把层级加一
（代码在 `stmt.c` 中）：

```c
// Parse a WHILE statement and return its AST
static struct ASTnode *while_statement(void) {
  ...
  // Get the AST for the compound statement.
  // Update the loop depth in the process
  Looplevel++;
  bodyAST = compound_statement();
  Looplevel--;
  ...
}

// Parse a FOR statement and return its AST
static struct ASTnode *for_statement(void) {
  ...
  // Get the compound statement which is the body
  // Update the loop depth in the process
  Looplevel++;
  bodyAST = compound_statement();
  Looplevel--;
  ...
}
```

这样一来，
我们就能判断自己当前到底是在循环内部，
还是根本不在循环里。

## 测试代码

下面是测试程序 `tests/input71.c`：

```c
#include <stdio.h>

int main() {
  int x;
  x = 0;
  while (x < 100) {
    if (x == 5) { x = x + 2; continue; }
    printf("%d\n", x);
    if (x == 14) { break; }
    x = x + 1;
  }
  printf("Done\n");
  return (0);
}
```

因为我还没有解决 “dangling else” 问题，
所以这里的 `break`
还必须放在 `'{ ... }'`
这样的复合语句里。
除此之外，
这段代码的行为是符合预期的：

```
0
1
2
3
4
7
8
9
10
11
12
13
14
Done
```

## 总结与下一步

我一开始就知道，
有了 AST 之后，
给 `break` 和 `continue` 增加支持
肯定会比我上一个编译器轻松不少。
不过在真正实现过程中，
还是出现了一些小问题和小褶皱，
需要逐个处理。

现在既然语言里已经有了 `break`，
下一部分我就要尝试加入 `switch` 语句了。
这会要求我们实现 `switch` 的跳转表（jump table），
而我知道这件事不会简单。
所以，
准备迎接下一段有点意思的旅程吧。 [下一步](../37_Switch/Readme.md)
