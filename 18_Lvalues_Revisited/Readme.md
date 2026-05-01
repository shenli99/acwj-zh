# 第 18 部分：重新审视左值与右值

由于这整个项目一直都在边做边演进，
又没有一份完整设计文档来提前约束方向，
所以我偶尔不得不把已经写好的代码拆掉重写，
要么是为了把它改得更通用，
要么是为了修掉之前架构上的短板。
这一部分就是这样一个例子。

我们在第 15 部分里给指针做了第一版支持，
于是已经能写出这样的代码：

```c
  int  x;
  int *y;
  int  z;
  x= 12; y= &x; z= *y;
```

这些当然都没问题。
但我也很清楚，
我们迟早还得支持“把指针放在赋值语句左边”这种写法，
例如：

```c
  *y = 14;
```

为了做到这一点，
我们就必须重新回到
[lvalue 和 rvalue](https://en.wikipedia.org/wiki/Value_(computer_science)#lrvalue)
这个话题上。
简单回顾一下：
*lvalue* 是绑定到某个具体存储位置上的值，
而 *rvalue* 则不是。
lvalue 具有持久性：
以后我们还可以继续把它的值再取出来。
相反，rvalue 是短暂的，
一旦用完就可以直接丢弃。

### rvalue 和 lvalue 的例子

rvalue 的一个例子是整数字面量，比如 23。
我们可以在表达式里用它，之后就把它丢掉。
而 lvalue 的例子则是那些“可以存值进去”的内存位置，例如：

```
   a            Scalar variable a
   b[0]         Element zero of array b
   *c           The location that pointer c points to
   (*d)[0]      Element zero of the array that d points to
```

正如我之前提过的，
*lvalue* 和 *rvalue* 这两个名字，
其实就来自赋值语句的左右两边：
lvalue 在左边，rvalue 在右边。

## 扩展我们对 lvalue 的理解

到目前为止，
编译器其实几乎把所有东西都当成 rvalue 来处理。
对于变量，
它会直接从变量所在位置取出值。
我们唯一对“lvalue 概念”的照顾，
就是把赋值左边的标识符标记成 `A_LVIDENT`。
然后在 `gen.c` 的 `genAST()` 中手工处理它：

```c
    case A_IDENT:
      return (cgloadglob(n->v.id));
    case A_LVIDENT:
      return (cgstorglob(reg, n->v.id));
    case A_ASSIGN:
      // The work has already been done, return the result
      return (rightreg);
```

这套逻辑可以应付 `a= b;` 这样的语句。
但现在我们需要做得更多：
赋值语句左边不再只是“标识符”，
而是很多种可能的 lvalue 形式。

此外，我们还得保证这个过程里生成汇编代码尽量顺手。
在写这一部分时，
我一度尝试过另一种设计：
在树的外面额外挂一个父节点 `A_LVALUE`，
用它告诉代码生成器：
这棵子树现在应该输出 lvalue 版本的代码，
而不是 rvalue 版本。
结果事实证明这已经太晚了：
因为那棵子树本身早就被求值过了，
rvalue 代码已经生成出来了。

### AST 节点又改了一次

我其实很不情愿再往 AST 节点里塞字段了，
但最后还是这么干了。
现在我们新增了一个字段，
用来表示这个节点应该生成的是 lvalue 代码还是 rvalue 代码：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  int type;                     // Type of any expression this tree generates
  int rvalue;                   // True if the node is an rvalue
  ...
};
```

`rvalue` 字段其实只保存 1 bit 的信息；
以后如果我还需要保存别的布尔属性，
完全可以把它改造成一个 bitfield。

问题是：为什么我把这个字段设计成“是否为 rvalue”，
而不是“是否为 lvalue”？
毕竟在 AST 里，大多数节点看起来明明更像是 rvalue。

我当时在读 Nils Holm 关于 SubC 的书时，
看到这样一句话：

> Since an indirection cannot be reversed later, the parser assumes each
  partial expression to be an lvalue.

考虑解析器处理语句 `b = a + 2` 的过程。
在它刚解析到标识符 `b` 时，
其实还无法判断这是一个 lvalue 还是 rvalue。
只有等看到 `=` token 的那一刻，
我们才能确定它是个 lvalue。

而且 C 语言允许把赋值写成表达式，
所以我们还能写出 `b = c = a + 2`。
同样地，在解析到 `a` 这个标识符的时候，
也还不能立刻知道它到底最终是 lvalue 还是 rvalue，
必须继续看后面的 token。

因此，我最终选择默认把每个 AST 节点都先当成 lvalue。
等到我们能够明确判断它必须是 rvalue 时，
再把 `rvalue` 字段设上去。

## 赋值表达式

前面我也提到过：
C 语言允许把赋值写成表达式。
现在既然已经把 lvalue / rvalue 的区别理清楚了，
我们就可以不再把赋值当成“语句解析器里的特殊逻辑”，
而是把它真正搬进表达式解析器里。
这一点我稍后会讲。

现在先来看看，
为了实现这一点，编译器代码到底被改成了什么样。
和往常一样，先从 token 和扫描器说起。

## token 与扫描器的变化

这次没有新增 token，也没有新增关键字。
但有一个会影响 token 体系的变化：
现在 `=` 变成了一个真正的二元运算符，
它左右两边都接表达式，
所以必须把它和其他二元运算符整合到一起。

根据
[这份 C 运算符列表](https://en.cppreference.com/w/c/language/operator_precedence)，
`=` 的优先级远低于 `+` 和 `-`。
因此我们得重新排列运算符列表及其优先级。
在 `defs.h` 中：

```c
// Token types
enum {
  T_EOF,
  // Operators
  T_ASSIGN,
  T_PLUS, T_MINUS, ...
```

在 `expr.c` 中，
则需要更新保存二元运算符优先级的代码：

```c
// Operator precedence for each token. Must
// match up with the order of tokens in defs.h
static int OpPrec[] = {
   0, 10,                       // T_EOF,  T_ASSIGN
  20, 20,                       // T_PLUS, T_MINUS
  30, 30,                       // T_STAR, T_SLASH
  40, 40,                       // T_EQ, T_NE
  50, 50, 50, 50                // T_LT, T_GT, T_LE, T_GE
};
```

## 解析器的变化

现在我们必须把“赋值作为语句”的解析逻辑删掉，
转而把它变成“赋值作为表达式”。
同时我也顺手把语言里的 `print` 语句去掉了，
因为现在我们已经可以直接调用 `printint()`。
于是，在 `stmt.c` 中，
我删掉了 `print_statement()` 和 `assignment_statement()`。

> 我还同时删掉了语言中的 `T_PRINT` 以及 `'print'` 关键字。
  此外，既然现在我们对 lvalue 和 rvalue 的理解已经不同了，
  `A_LVIDENT` 这个 AST 节点类型也一并去掉了。

目前，`stmt.c` 中 `single_statement()` 的语句解析逻辑，
如果识别不出开头 token 是什么，
就会先假设“这可能是个表达式”：

```c
static struct ASTnode *single_statement(void) {
  int type;

  switch (Token.token) {
    ...
    default:
    // For now, see if this is an expression.
    // This catches assignment statements.
    return (binexpr(0));
  }
}
```

这也意味着像 `2+3;` 这样的东西，
暂时也会被当成合法语句。
这个问题以后再修。
同时在 `compound_statement()` 中，
我们还会确保这种表达式后面确实跟了分号：

```c
    // Some statements must be followed by a semicolon
    if (tree != NULL && (tree->op == A_ASSIGN ||
                         tree->op == A_RETURN || tree->op == A_FUNCCALL))
      semi();
```

## 表达式解析

你可能会觉得：
既然 `=` 已经被标成了二元表达式运算符，
而且优先级也已经设置好了，
那是不是就完事了？还没有！
我们还得额外解决两件事：

1. 生成汇编时，必须先生成右边 rvalue 的代码，
   再生成左边 lvalue 的代码。
   之前这件事是在语句解析器里手工处理的，
   现在得搬进表达式解析器。
2. 赋值表达式是**右结合（right associative）**的：
   这个运算符会更紧地绑定在右边表达式上。

之前我们还没有真正处理过“右结合”。
先看一个例子。
对于表达式 `2 + 3 + 4`，
我们从左到右解析完全没问题，
构造出来的 AST 会是：

```
      +
     / \
    +   4
   / \
  2   3
```

但对于表达式 `a= b= 3`，
如果照同样思路来，
最终会得到这棵树：
   
```
      =
     / \
    =   3
   / \
  a   b
```

这显然不是我们想要的，
因为那意味着先做 `a= b`，
然后才试图把 3 赋给这整棵左子树。
而我们真正想要的是下面这样：

```
        =
       / \
      =   a
     / \
    3   b
```

这里我把叶子节点反过来摆放了，
使其更符合汇编输出顺序：
先把 3 存进 `b`，
然后这个赋值表达式的结果（也就是 3）
再被存进 `a`。

### 修改 Pratt 解析器

我们当前用的是 Pratt parser 来正确解析二元运算符优先级。
为了加入右结合支持，
我专门查了一下 Pratt parser 该怎么处理，
结果在
[Wikipedia](https://en.wikipedia.org/wiki/Operator-precedence_parser)
上找到这样一段说明：

```
   while lookahead is a binary operator whose precedence is greater than op's,
   or a right-associative operator whose precedence is equal to op's
```

也就是说，
对于右结合运算符，
当下一个运算符的优先级和当前运算符*相等*时，
我们同样还要继续处理。
这只是对解析器逻辑的一点小修改。
于是我在 `expr.c` 中新增了一个函数，
用来判断某个运算符是否是右结合的：

```c
// Return true if a token is right-associative,
// false otherwise.
static int rightassoc(int tokentype) {
  if (tokentype == T_ASSIGN)
    return(1);
  return(0);
}

```

随后在 `binexpr()` 中，
我们按前面的规则改了 `while` 循环条件；
同时针对 `A_ASSIGN` 加入了专门逻辑，
把左右孩子交换顺序：

```c
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  struct ASTnode *ltemp, *rtemp;
  int ASTop;
  int tokentype;

  // Get the tree on the left.
  left = prefix();
  ...

  // While the precedence of this token is more than that of the
  // previous token precedence, or it's right associative and
  // equal to the previous token's precedence
  while ((op_precedence(tokentype) > ptp) ||
         (rightassoc(tokentype) && op_precedence(tokentype) == ptp)) {
    ...
    // Recursively call binexpr() with the
    // precedence of our token to build a sub-tree
    right = binexpr(OpPrec[tokentype]);

    ASTop = binastop(tokentype);
    if (ASTop == A_ASSIGN) {
      // Assignment
      // Make the right tree into an rvalue
      right->rvalue= 1;
      ...

      // Switch left and right around, so that the right expression's 
      // code will be generated before the left expression
      ltemp= left; left= right; right= ltemp;
    } else {
      // We are not doing an assignment, so both trees should be rvalues
      left->rvalue= 1;
      right->rvalue= 1;
    }
    ...
  }
  ...
}
```

还要注意这里有一段显式代码，
会把赋值表达式右边那棵子树标记成 rvalue。
而对于非赋值表达式，
左右两边都会被标记成 rvalue。

在 `binexpr()` 的其他位置里，
还散落着几行“显式把某棵树标成 rvalue”的代码。
这些是在我们碰到叶子节点时才会触发的。
例如在 `b= a;` 里，
标识符 `a` 必须被标记成 rvalue，
但这时我们未必会进入 `while` 循环体中去做这件事。

## 把 AST 树打印出来

到这里，解析器改动就差不多了。
现在有些节点被标成了 rvalue，
有些则完全没标。
这时我意识到，
自己已经很难在脑子里直观想清楚到底生成了什么 AST。

因此我在 `tree.c` 中写了一个叫 `dumpAST()` 的函数，
把每棵 AST 直接打印到标准输出上。
它并不复杂。
编译器现在支持一个命令行参数 `-T`，
它会设置一个内部标志 `O_dumpAST`。
而 `decl.c` 中 `global_declarations()` 现在会这样做：

```c
       // Parse a function declaration and
       // generate the assembly code for it
       tree = function_declaration(type);
       if (O_dumpAST) {
         dumpAST(tree, NOLABEL, 0);
         fprintf(stdout, "\n\n");
       }
       genAST(tree, NOLABEL, 0);

```

这个树打印器会按照树的遍历顺序输出每个节点，
因此它并不会真正画出一棵“树形图”。
不过每个节点的缩进深度，
能够反映它在树中的层级。

下面看几个赋值表达式的 AST 示例。
先从 `a= b= 34;` 开始：

```
      A_INTLIT 34
    A_WIDEN
    A_IDENT b
  A_ASSIGN
  A_IDENT a
A_ASSIGN
```

34 足够小，所以最初它会被当成一个 `char` 大小的字面量，
但随后它会被扩宽，
以匹配 `b` 的类型。
`A_IDENT b` 没有写 “rvalue”，
所以它是个 lvalue。
34 的值会先被存进 lvalue `b`，
然后这个赋值表达式的结果再被存进 lvalue `a`。

再看 `a= b + 34;`：

```
    A_IDENT rval b
      A_INTLIT 34
    A_WIDEN
  A_ADD
  A_IDENT a
A_ASSIGN
```

这次你就能看到 “rval `b`” 了，
说明会先把 `b` 的值加载到寄存器中；
而 `b+34` 这个表达式的结果，
最终再被存进 lvalue `a`。

再来一个，`*x= *y`：

```
    A_IDENT y
  A_DEREF rval
    A_IDENT x
  A_DEREF
A_ASSIGN
```

这里先对标识符 `y` 做解引用，
取得这个 rvalue 并加载出来；
然后再把它存进那个 lvalue，
也就是“对 `x` 解引用后得到的位置”。

## 把上面的树翻译成代码

既然现在 lvalue 和 rvalue 节点已经区分得很清楚了，
接下来就该看：
如何把它们分别翻译成汇编代码。

像整数字面量、加法之类的节点，
本质上都只能是 rvalue，
因此 `gen.c` 里的 `genAST()` 真正需要关心的，
只是那些“有可能成为 lvalue”的 AST 节点类型。
下面是我现在对这些节点的处理：

```c
    case A_IDENT:
      // Load our value if we are an rvalue
      // or we are being dereferenced
      if (n->rvalue || parentASTop== A_DEREF)
        return (cgloadglob(n->v.id));
      else
        return (NOREG);

    case A_ASSIGN:
      // Are we assigning to an identifier or through a pointer?
      switch (n->right->op) {
        case A_IDENT: return (cgstorglob(leftreg, n->right->v.id));
        case A_DEREF: return (cgstorderef(leftreg, rightreg, n->right->type));
        default: fatald("Can't A_ASSIGN in genAST(), op", n->op);
      }

    case A_DEREF:
      // If we are an rvalue, dereference to get the value we point at
      // otherwise leave it for A_ASSIGN to store through the pointer
      if (n->rvalue)
        return (cgderef(leftreg, n->left->type));
      else
        return (leftreg);
```

### x86-64 代码生成器的变化

`cg.c` 中唯一新增的内容，
是一个允许我们“通过指针去存值”的函数：

```c
// Store through a dereferenced pointer
int cgstorderef(int r1, int r2, int type) {
  switch (type) {
    case P_CHAR:
      fprintf(Outfile, "\tmovb\t%s, (%s)\n", breglist[r1], reglist[r2]);
      break;
    case P_INT:
      fprintf(Outfile, "\tmovq\t%s, (%s)\n", reglist[r1], reglist[r2]);
      break;
    case P_LONG:
      fprintf(Outfile, "\tmovq\t%s, (%s)\n", reglist[r1], reglist[r2]);
      break;
    default:
      fatald("Can't cgstoderef on type:", type);
  }
  return (r1);
}
```

它几乎就是前面 `cgderef()` 的反向操作，
而且就在那个函数后面。

## 总结与下一步

为了完成这一部分内容，
我大概试过两三种不同设计方向，
每种都走到一半才发现有死路，
最后再回退出来，才得到这里描述的方案。

我知道在 SubC 里，
Nils 是通过传递一个统一的“lvalue 结构体”，
来保存当前正在处理的 AST 节点的“是否是 lvalue”信息。
但他的 AST 只表示一条表达式；
而我们这里的 AST 是整整一个函数级别的树。
而且我敢肯定，
如果你再去看另外三个编译器，
多半还能找到另外三种不同的处理方法。

接下来可以做的事情还有很多。
不少 C 运算符其实都可以相对轻松地加进来。
我们现在已经有了 `A_SCALE`，
所以也许可以尝试结构体。
到现在为止，局部变量还根本不存在，
这迟早也得补上。
此外，函数也还需要推广到支持多参数以及访问这些参数。

在编译器编写之旅的下一部分中，
我想先处理数组。
它会把解引用、lvalue 与 rvalue、
以及“按元素大小缩放数组索引”这些问题全部揉在一起。
我们已经把所有语义组件准备得差不多了，
接下来还需要补 token、解析逻辑，
以及真正的下标访问功能。
它应该会像这一部分一样，是个很有意思的话题。 [下一步](../19_Arrays_pt1/Readme.md)
