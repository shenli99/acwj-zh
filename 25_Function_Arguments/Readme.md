# 第 25 部分：函数调用与实参

在编译器编写之旅的这一部分里，
我要给编译器加入“以任意数量实参调用函数”的能力；
实参的值会被复制到函数形参中，
并作为局部变量出现在函数体里。

我之前还没动手做这件事，
因为在开始编码之前，
还有一些设计问题需要先想清楚。
照例，
我们再回看一次 Eli Bendersky 那篇文章里的图：
[x86-64 栈帧布局](https://eli.thegreenplace.net/2011/09/06/stack-frame-layout-on-x86-64/)。

![](../22_Design_Locals/Figs/x64_frame_nonleaf.png)

一个函数最多前六个“值传递（call by value）”实参
会通过寄存器 `%rdi` 到 `%r9` 传入。
超过六个以后，
剩余实参会被压到栈上。

仔细看一下栈上的实参值。
虽然 `h` 是最后一个实参，
但它会最先被压入那个“向下增长”的栈中；
而 `g` 这个实参，
则是在 `h` *之后* 才被压栈。

C 语言里一个相当糟糕的点在于：
表达式求值顺序并没有被定义。
正如
[这里](https://en.cppreference.com/w/c/language/eval_order)
所说：

> [The] order of evaluation of the operands of any C operator, including
  the order of evaluation of function arguments in a function-call
  expression ... is unspecified ... . The compiler will evaluate them
  in any order ...

这会让语言天然带有一定程度的不可移植性：
同一段代码在某个平台、某个编译器上的行为，
换到另一个平台或另一个编译器后，
有可能表现不同。

但对我们来说，
这种“没有定义求值顺序”的特性反而暂时成了一件*好事*，
因为这意味着：
我们可以按照“更方便编译器实现”的顺序去生成实参值。
我这里说得有点轻描淡写了；
严格来说，
这其实并不是什么真正意义上的好事。

由于 x86-64 平台要求“最后一个实参的值先被压栈”，
所以我必须把处理实参的代码写成“从最后一个到第一个”。
不过我也应该确保，
这套代码以后能比较容易改成反过来的处理方向：
也许可以加一个 `genXXX()` 查询函数，
让代码根据目标架构决定“应该按哪个方向处理参数”。
这部分我以后再补。

### 生成表达式的 AST

我们已经有 `A_GLUE` 这种 AST 节点类型了，
所以写一个函数去解析实参表达式列表并构建 AST 应该不难。
对于函数调用 `function(expr1, expr2, expr3, expr4)`，
我决定把树构造成这样：

```
                 A_FUNCCALL
                  /
              A_GLUE
               /   \
           A_GLUE  expr4
            /   \
        A_GLUE  expr3
         /   \
     A_GLUE  expr2
     /    \
   NULL  expr1
```

每个表达式都放在右边，
而之前已经解析出来的表达式树则挂在左边。
这样我在遍历这棵“表达式子树”时，
就必须从右往左走，
以确保在 x86-64 上需要先压栈的 `expr4`
会在 `expr3` 之前被处理。

我们已经有一个 `funccall()`，
它原本只能解析“永远只有一个参数”的简单函数调用。
我准备修改它，
让它去调用 `expression_list()`，
由后者负责解析表达式列表并构建 `A_GLUE` 子树。
这个函数会把表达式个数存进最顶层 `A_GLUE` 节点，
并把这个计数返回出来。
之后在 `funccall()` 里，
我们就可以把所有表达式的类型
与保存在全局符号表中的函数原型做比较。

设计层面我觉得差不多讲够了。
下面开始看具体实现。

## 表达式解析的变更

嗯，
代码我大概一个小时就写完了，
自己还有点意外。
借用一句常在 Twitter 上流传的话：

> Weeks of programming can save you hours of planning.

反过来说，
前面多花一点时间做设计，
通常确实能提升后面写代码的效率。
下面来看看改动。
我们先从解析部分开始。

现在我们要解析“逗号分隔的表达式列表”，
并构建那棵 `A_GLUE` AST：
子表达式放在右子树，
更早的表达式树挂在左子树。
`expr.c` 里的代码如下：

```c
// expression_list: <null>
//        | expression
//        | expression ',' expression_list
//        ;

// Parse a list of zero or more comma-separated expressions and
// return an AST composed of A_GLUE nodes with the left-hand child
// being the sub-tree of previous expressions (or NULL) and the right-hand
// child being the next expression. Each A_GLUE node will have size field
// set to the number of expressions in the tree at this point. If no
// expressions are parsed, NULL is returned
static struct ASTnode *expression_list(void) {
  struct ASTnode *tree = NULL;
  struct ASTnode *child = NULL;
  int exprcount = 0;

  // Loop until the final right parentheses
  while (Token.token != T_RPAREN) {

    // Parse the next expression and increment the expression count
    child = binexpr(0);
    exprcount++;

    // Build an A_GLUE AST node with the previous tree as the left child
    // and the new expression as the right child. Store the expression count.
    tree = mkastnode(A_GLUE, P_NONE, tree, NULL, child, exprcount);

    // Must have a ',' or ')' at this point
    switch (Token.token) {
      case T_COMMA:
        scan(&Token);
        break;
      case T_RPAREN:
        break;
      default:
        fatald("Unexpected token in expression list", Token.token);
    }
  }

  // Return the tree of expressions
  return (tree);
}
```

这部分写起来比我原本预想的简单多了。
接下来，
我们要把它接到现有的函数调用解析器上：

```c
// Parse a function call and return its AST
static struct ASTnode *funccall(void) {
  struct ASTnode *tree;
  int id;

  // Check that the identifier has been defined as a function,
  // then make a leaf node for it.
  if ((id = findsymbol(Text)) == -1 || Symtable[id].stype != S_FUNCTION) {
    fatals("Undeclared function", Text);
  }
  // Get the '('
  lparen();

  // Parse the argument expression list
  tree = expression_list();

  // XXX Check type of each argument against the function's prototype

  // Build the function call AST node. Store the
  // function's return type as this node's type.
  // Also record the function's symbol-id
  tree = mkastunary(A_FUNCCALL, Symtable[id].type, tree, id);

  // Get the ')'
  rparen();
  return (tree);
}
```

注意里面那个 `XXX`，
这是我给自己留的提醒，
表示还有活没做完。
目前解析器已经会检查：
这个函数是否在之前声明过。
但它还没有拿实参类型去和函数原型做逐项对比。
这部分我很快就会补上。

现在返回出来的 AST，
形状已经和文章开头我画出来的那棵树一致了。
接下来就是遍历它并生成汇编代码。

## 通用代码生成器的变更

这个编译器的结构是这样的：
负责遍历 AST 的那一层是架构无关的，
位于 `gen.c`；
而真正平台相关的后端则在 `cg.c` 中。
所以我们先看 `gen.c` 里的变化。

遍历这个新 AST 结构需要一段不算太短的逻辑，
因此我专门写了一个处理函数调用的函数。
现在 `genAST()` 里有了这一段：

```c
  // n is the AST node being processed
  switch (n->op) {
    ...
    case A_FUNCCALL:
      return (gen_funccall(n));
  }
```

而遍历新 AST 结构的代码在这里：

```c
// Generate the code to copy the arguments of a
// function call to its parameters, then call the
// function itself. Return the register that holds 
// the function's return value.
static int gen_funccall(struct ASTnode *n) {
  struct ASTnode *gluetree = n->left;
  int reg;
  int numargs=0;

  // If there is a list of arguments, walk this list
  // from the last argument (right-hand child) to the
  // first
  while (gluetree) {
    // Calculate the expression's value
    reg = genAST(gluetree->right, NOLABEL, gluetree->op);
    // Copy this into the n'th function parameter: size is 1, 2, 3, ...
    cgcopyarg(reg, gluetree->v.size);
    // Keep the first (highest) number of arguments
    if (numargs==0) numargs= gluetree->v.size;
    genfreeregs();
    gluetree = gluetree->left;
  }

  // Call the function, clean up the stack (based on numargs),
  // and return its result
  return (cgcall(n->v.id, numargs));
}
```

这里有几点值得注意。
表达式代码是通过对右孩子调用 `genAST()` 生成的。
同时，
我们把 `numargs` 设成第一次读到的 `size` 值，
它也就是实参数量
（注意这里是从 1 开始计数，而不是从 0）。
然后调用 `cgcopyarg()`，
把这个值复制到函数的第 *n* 个参数位置。

复制完成后，
我们就可以把寄存器全部释放，
为下一个表达式做准备；
然后再沿着左孩子走向“前一个表达式”。

最后，
我们调用 `cgcall()` 来生成真正的函数调用。
因为在这个过程中我们可能已经把若干参数压到了栈上，
所以还需要把总实参数量也传给它，
好让它能算出调用后该从栈上弹回多少内容。

这里还没有牵涉任何硬件相关代码；
不过正如我在前面提到的，
我们现在是从“最后一个表达式”走到“第一个表达式”。
并不是所有架构都喜欢这个顺序，
因此这部分以后仍然有空间做得更灵活一些，
比如让它根据目标架构选择求值顺序。

## `cg.c` 的变更

现在终于轮到真正生成 x86-64 汇编输出的函数了。
我们新增了一个 `cgcopyarg()`，
并修改了现有的 `cgcall()`。

不过先回顾一下，
我们当前有这样几组寄存器列表：

```c
#define FIRSTPARAMREG 9         // Position of first parameter register
static char *reglist[] =
  { "%r10", "%r11", "%r12", "%r13", "%r9", "%r8", "%rcx", "%rdx", "%rsi", "%rdi" };

static char *breglist[] =
  { "%r10b", "%r11b", "%r12b", "%r13b", "%r9b", "%r8b", "%cl", "%dl", "%sil", "%dil" };

static char *dreglist[] =
  { "%r10d", "%r11d", "%r12d", "%r13d", "%r9d", "%r8d", "%ecx", "%edx", "%esi", "%edi" };
```

`FIRSTPARAMREG` 设在最后一个索引位置，
也就是说我们会沿着这个数组往前倒着走。

另外别忘了：
我们拿到的参数位置编号是从 1 开始的
（也就是 1、2、3、4……），
而不是从 0 开始；
但上面的数组却是从 0 开始编号。
所以你会在下面代码里看到几个 `+1` 或 `-1` 的调整。

下面是 `cgcopyarg()`：

```c
// Given a register with an argument value,
// copy this argument into the argposn'th
// parameter in preparation for a future function
// call. Note that argposn is 1, 2, 3, 4, ..., never zero.
void cgcopyarg(int r, int argposn) {

  // If this is above the sixth argument, simply push the
  // register on the stack. We rely on being called with
  // successive arguments in the correct order for x86-64
  if (argposn > 6) {
    fprintf(Outfile, "\tpushq\t%s\n", reglist[r]);
  } else {
    // Otherwise, copy the value into one of the six registers
    // used to hold parameter values
    fprintf(Outfile, "\tmovq\t%s, %s\n", reglist[r],
            reglist[FIRSTPARAMREG - argposn + 1]);
  }
}
```

相当直接，
除了那个 `+1` 稍微要动点脑子。
接着是 `cgcall()`：

```c
// Call a function with the given symbol id
// Pop off any arguments pushed on the stack
// Return the register with the result
int cgcall(int id, int numargs) {
  // Get a new register
  int outr = alloc_register();
  // Call the function
  fprintf(Outfile, "\tcall\t%s\n", Symtable[id].name);
  // Remove any arguments pushed on the stack
  if (numargs>6) 
    fprintf(Outfile, "\taddq\t$%d, %%rsp\n", 8*(numargs-6));
  // and copy the return value into our register
  fprintf(Outfile, "\tmovq\t%%rax, %s\n", reglist[outr]);
  return (outr);
}
```

同样也很简洁。

## 测试这些改动

在编译器编写之旅的上一部分中，
我们有两个分开的测试程序 `input27a.c` 和 `input27b.c`：
其中一个还得用 `gcc` 去编译。
而现在，
我们已经可以把它们合并在一起，
并全部交给自己的编译器去处理了。
此外还有第二个测试程序 `input28.c`，
里面放了更多函数调用示例。
照例：

```
$ make test
cc -o comp1 -g -Wall cg.c decl.c expr.c gen.c main.c
    misc.c scan.c stmt.c sym.c tree.c types.c
(cd tests; chmod +x runtests; ./runtests)
  ...
input25.c: OK
input26.c: OK
input27.c: OK
input28.c: OK
```

## 总结与下一步

到现在为止，
我觉得我们的编译器已经从一个“玩具编译器”
迈进到了一个“开始有点实际用途”的状态：
我们现在终于可以写多函数程序，
并在这些函数之间相互调用了。
虽然走到这里花了好几个步骤，
但我觉得每一步都不算特别巨大。

当然，
前面的路还很长。
我们还需要加上结构体（struct）、
联合体（union）、
外部标识符（external identifier）
以及预处理器（pre-processor）。
然后还得让编译器更稳健，
提供更好的错误检测，
甚至也许还要加警告机制等等。
所以也许，
现在的进度大概只走到一半。

在编译器编写之旅的下一部分中，
我打算先加入“函数原型（function prototype）”的书写能力。
这样一来，
我们就可以链接外部函数了。
我想到的是那些经典 Unix 函数和系统调用，
例如基于 `int` 和 `char *` 的 `open()`、
`read()`、`write()`、`strcpy()` 等等。
如果能用我们的编译器编出一些真正有用的小程序，
那会很不错。 [下一步](../26_Prototypes/Readme.md)
