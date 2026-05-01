# 第 12 部分：类型，第 1 部分

我刚刚开始把类型加入编译器。
先说明一下：这对我来说也是新的领域，
因为在我
[之前写的编译器](https://github.com/DoctorWkt/h-compiler)
里，只有 `int` 一种类型。
我还刻意忍住没有去看 SubC 的源码找思路。
所以这一次我算是自己摸着石头过河，
而且随着类型问题越来越复杂，
我很可能还得回过头重写一部分代码。

## 目前先支持哪些类型？

对全局变量来说，我先支持 `char` 和 `int`。
函数部分我们已经加入了 `void` 关键字。
下一步我会再加上函数返回值。
所以现在虽然有 `void`，
但我还没有把它完整地纳入整个类型体系里。

显然，`char` 的取值范围要比 `int` 小得多。
和 SubC 一样，
我打算让 `char` 采用 0 到 255 的范围，
而 `int` 则采用有符号整数范围。

这意味着：
我们可以把 `char` 扩宽（widen）成 `int`，
但如果开发者想把 `int` 缩窄到 `char` 的范围，
我们就必须给出警告，甚至拒绝这种行为。

## 新关键字与 token

这里唯一新增的只有关键字 `char`，
以及 token `T_CHAR`。
没有什么特别激动人心的变化。

## 表达式类型

从现在开始，每个表达式都会有一个类型。
这包括：

 + 整数字面量，例如 56 是一个 `int`
 + 数学表达式，例如 `45 - 12` 是一个 `int`
 + 变量，例如如果我们把 `x` 声明成 `char`，
   那它的 *rvalue* 类型就是 `char`

我们必须在求值表达式的过程中一路跟踪类型，
从而判断什么时候需要扩宽，
什么时候必须拒绝不合法的缩窄。

在 SubC 编译器里，Nils 创建了一个统一的 *lvalue* 结构体。
递归解析器在解析任何表达式时，
都会把指向这一个结构体的指针一路传递下去，
从而追踪当前表达式的类型。

我采用了另一条路。
我修改了抽象语法树节点，
给它加了一个 `type` 字段，
用来保存该节点对应树在当前位置的类型。
在 `defs.h` 中，目前我定义的类型如下：

```c
// Primitive types
enum {
  P_NONE, P_VOID, P_CHAR, P_INT
};
```

我把它们叫作 *primitive* types，
也是沿用了 SubC 的说法，
因为我暂时也想不到更好的名字。
也许叫“基础类型”更合适？
其中 `P_NONE` 表示该 AST 节点*并不表示一个表达式*，
因此没有类型。
一个例子就是 `A_GLUE` 节点：
它只是把语句粘接在一起，
左边的语句代码生成完之后，
并不存在什么“类型”可言。

如果你去看 `tree.c`，
会发现构建 AST 节点的那些函数现在都被修改过了，
它们会同时给新 AST 结构里的 `type` 字段赋值
（定义于 `defs.h`）：

```c
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  int type;                     // Type of any expression this tree generates
  ...
};
```

## 变量声明以及它们的类型

现在我们至少已经有两种方式可以声明全局变量：

```c
  int x; char y;
```

当然，我们需要能解析它。
但在那之前，要先回答一个问题：
每个变量的类型该如何记录？
因此我们需要修改 `symtable` 结构。
我还顺手加入了符号“结构类型（structural type）”的信息，
以后会用得上（定义于 `defs.h`）：

```c
// Structural types
enum {
  S_VARIABLE, S_FUNCTION
};

// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  int stype;                    // Structural type for the symbol
};
```

在 `sym.c` 的 `newglob()` 里，
现在也有了初始化这些新字段的代码：

```c
int addglob(char *name, int type, int stype) {
  ...
  Gsym[y].type = type;
  Gsym[y].stype = stype;
  return (y);
}
```

## 解析变量声明

现在该把“解析类型”和“解析变量本身”这两件事拆开了。
于是，在 `decl.c` 中我们现在有：

```c
// Parse the current token and
// return a primitive type enum value
int parse_type(int t) {
  if (t == T_CHAR) return (P_CHAR);
  if (t == T_INT)  return (P_INT);
  if (t == T_VOID) return (P_VOID);
  fatald("Illegal type, token", t);
}

// Parse the declaration of a variable
void var_declaration(void) {
  int id, type;

  // Get the type of the variable, then the identifier
  type = parse_type(Token.token);
  scan(&Token);
  ident();
  id = addglob(Text, type, S_VARIABLE);
  genglobsym(id);
  semi();
}
```

## 处理表达式类型

上面的部分都算是简单部分，已经做完了。
现在我们有了：

  + 三种类型：`char`、`int` 和 `void`
  + 变量声明的类型解析逻辑
  + 在符号表里记录每个变量类型的能力
  + 在每个 AST 节点里保存表达式类型的能力

接下来真正麻烦的是：
把这些类型信息实际填进我们构建出来的 AST 节点里。
然后，我们还得决定什么时候需要扩宽类型，
什么时候需要拒绝类型冲突。
继续动手吧。

## 解析基础终结符

先从整数字面量和变量标识符的解析开始。
这里有个小细节：
我们希望下面这样的代码能够工作：

```c
  char j; j= 2;
```

但如果我们把 `2` 直接标记成 `P_INT`，
那之后存进 `P_CHAR` 类型的变量 `j` 时，
就没法顺利完成缩窄。
所以目前我加了一些语义逻辑：
把小范围的整数字面量先保留成 `P_CHAR`：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;

  switch (Token.token) {
    case T_INTLIT:
      // For an INTLIT token, make a leaf AST node for it.
      // Make it a P_CHAR if it's within the P_CHAR range
      if ((Token.intvalue) >= 0 && (Token.intvalue < 256))
        n = mkastleaf(A_INTLIT, P_CHAR, Token.intvalue);
      else
        n = mkastleaf(A_INTLIT, P_INT, Token.intvalue);
      break;

    case T_IDENT:
      // Check that this identifier exists
      id = findglob(Text);
      if (id == -1)
        fatals("Unknown variable", Text);

      // Make a leaf AST node for it
      n = mkastleaf(A_IDENT, Gsym[id].type, id);
      break;

    default:
      fatald("Syntax error, token", Token.token);
  }

  // Scan in the next token and return the leaf node
  scan(&Token);
  return (n);
}
```

另外还要注意，对于标识符来说，
我们很容易就能从全局符号表中拿到它的类型信息。

## 构建二元表达式：比较类型

在构建带有二元数学运算符的表达式时，
我们会拿到左孩子的类型和右孩子的类型。
这正是必须决定“扩宽、保持不变，还是直接拒绝表达式”的地方。

目前我新建了一个 `types.c` 文件，
里面有一个函数专门比较左右两边的类型。代码如下：

```c
// Given two primitive types, return true if they are compatible,
// false otherwise. Also return either zero or an A_WIDEN
// operation if one has to be widened to match the other.
// If onlyright is true, only widen left to right.
int type_compatible(int *left, int *right, int onlyright) {

  // Voids not compatible with anything
  if ((*left == P_VOID) || (*right == P_VOID)) return (0);

  // Same types, they are compatible
  if (*left == *right) { *left = *right = 0; return (1);
  }

  // Widen P_CHARs to P_INTs as required
  if ((*left == P_CHAR) && (*right == P_INT)) {
    *left = A_WIDEN; *right = 0; return (1);
  }
  if ((*left == P_INT) && (*right == P_CHAR)) {
    if (onlyright) return (0);
    *left = 0; *right = A_WIDEN; return (1);
  }
  // Anything remaining is compatible
  *left = *right = 0;
  return (1);
}
```

这里面的事情不少。
首先，如果两个类型完全一样，
那就可以直接返回 True。
而任何和 `P_VOID` 搭配的情况都不允许。

如果一边是 `P_CHAR`，另一边是 `P_INT`，
那么我们就可以把较窄的一边扩宽成 `P_INT`。
我的做法是直接修改传入的类型信息：
把它改成 0（表示“不需要做事”），
或者改成一个新的 AST 节点类型 `A_WIDEN`。
它的含义是：
把较窄孩子的值扩宽到与较宽孩子一致。
很快就能看到它的实际用法。

这里还有一个额外参数 `onlyright`。
它会在处理 `A_ASSIGN` AST 节点时派上用场，
因为赋值语句是把左孩子表达式的值
赋给右边那个变量 *lvalue*。
如果这个参数被设置，
我们就不允许把一个 `P_INT` 表达式塞进 `P_CHAR` 变量。

最后，目前先让剩余的其他类型组合全部通过。

我几乎可以肯定：
等以后把数组和指针引进来之后，
这段逻辑肯定还得改。
我也希望到时候能把它改得更简单、更优雅一点。
但眼下先够用。

## 在表达式中使用 `type_compatible()`

这一版编译器里，我在三个地方用了 `type_compatible()`。
先从用二元运算符合并表达式的地方说起。
我修改了 `expr.c` 中 `binexpr()` 的代码，如下：

```c
    // Ensure the two types are compatible.
    lefttype = left->type;
    righttype = right->type;
    if (!type_compatible(&lefttype, &righttype, 0))
      fatal("Incompatible types");

    // Widen either side if required. type vars are A_WIDEN now
    if (lefttype)
      left = mkastunary(lefttype, right->type, left, 0);
    if (righttype)
      right = mkastunary(righttype, left->type, right, 0);

    // Join that sub-tree with ours. Convert the token
    // into an AST operation at the same time.
    left = mkastnode(arithop(tokentype), left->type, left, NULL, right, 0);
```

如果类型不兼容，我们直接拒绝。
而如果 `type_compatible()` 返回的 `lefttype` 或 `righttype`
不是 0，
它们其实就是 `A_WIDEN`。
于是我们就可以构建一个一元 AST 节点，
把较窄的那个孩子挂在下面。
这样代码生成器在后面就知道：
这个孩子的值必须被扩宽。

那么，除了这里以外，
我们还在哪些地方需要扩宽表达式值？

## 用 `type_compatible()` 处理 `print`

当我们使用 `print` 关键字时，
需要保证传进去的是一个 `int` 表达式。
因此我们要修改 `stmt.c` 中的 `print_statement()`：

```c
static struct ASTnode *print_statement(void) {
  struct ASTnode *tree;
  int lefttype, righttype;
  int reg;

  ...
  // Parse the following expression
  tree = binexpr(0);

  // Ensure the two types are compatible.
  lefttype = P_INT; righttype = tree->type;
  if (!type_compatible(&lefttype, &righttype, 0))
    fatal("Incompatible types");

  // Widen the tree if required. 
  if (righttype) tree = mkastunary(righttype, P_INT, tree, 0);
```

## 用 `type_compatible()` 处理赋值

这是第三个需要做类型检查的地方。
给变量赋值时，
我们必须确认右值表达式能否被扩宽到左边变量所要求的类型；
同时必须拒绝把宽类型硬塞进窄变量。
下面是 `stmt.c` 中 `assignment_statement()` 的新代码：

```c
static struct ASTnode *assignment_statement(void) {
  struct ASTnode *left, *right, *tree;
  int lefttype, righttype;
  int id;

  ...
  // Make an lvalue node for the variable
  right = mkastleaf(A_LVIDENT, Gsym[id].type, id);

  // Parse the following expression
  left = binexpr(0);

  // Ensure the two types are compatible.
  lefttype = left->type;
  righttype = right->type;
  if (!type_compatible(&lefttype, &righttype, 1))  // Note the 1
    fatal("Incompatible types");

  // Widen the left if required.
  if (lefttype)
    left = mkastunary(lefttype, right->type, left, 0);
```

注意这里调用 `type_compatible()` 时最后那个 `1`。
它强制执行了这样的语义规则：
不允许把更宽的值存进更窄的变量。

综合上面的修改，
我们现在已经可以解析若干类型，并落实一些基本合理的语义规则：
能扩宽时扩宽，阻止类型缩窄，并阻止不合适的类型冲突。
接下来就轮到代码生成侧了。

## x86-64 代码生成的变化

我们的汇编输出是基于寄存器的，
而寄存器本身大小基本固定。
我们真正能影响的是：

 + 变量在内存中的存储大小
 + 寄存器里实际使用多少位来保存数据，
   比如字符用一个字节，64 位整数用八个字节

我先从 `cg.c` 里的 x86-64 专用代码讲起，
然后再说明它在通用代码生成器 `gen.c` 里如何使用。

先从变量存储的生成开始：

```c
// Generate a global symbol
void cgglobsym(int id) {
  // Choose P_INT or P_CHAR
  if (Gsym[id].type == P_INT)
    fprintf(Outfile, "\t.comm\t%s,8,8\n", Gsym[id].name);
  else
    fprintf(Outfile, "\t.comm\t%s,1,1\n", Gsym[id].name);
}
```

我们从符号表里取出变量类型，
然后据此决定给它分配 1 字节还是 8 字节。
接下来是把值加载到寄存器里：

```c
// Load a value from a variable into a register.
// Return the number of the register
int cgloadglob(int id) {
  // Get a new register
  int r = alloc_register();

  // Print out the code to initialise it: P_CHAR or P_INT
  if (Gsym[id].type == P_INT)
    fprintf(Outfile, "\tmovq\t%s(\%%rip), %s\n", Gsym[id].name, reglist[r]);
  else
    fprintf(Outfile, "\tmovzbq\t%s(\%%rip), %s\n", Gsym[id].name, reglist[r]);
  return (r);
```

`movq` 会把 8 字节移动到 8 字节寄存器中。
`movzbq` 则会先把 8 字节寄存器清零，
然后再把 1 字节内容移动进去。
这也就隐式地完成了“把 1 字节值扩宽到 8 字节”的动作。
我们的存储函数与之类似：

```c
// Store a register's value into a variable
int cgstorglob(int r, int id) {
  // Choose P_INT or P_CHAR
  if (Gsym[id].type == P_INT)
    fprintf(Outfile, "\tmovq\t%s, %s(\%%rip)\n", reglist[r], Gsym[id].name);
  else
    fprintf(Outfile, "\tmovb\t%s, %s(\%%rip)\n", breglist[r], Gsym[id].name);
  return (r);
}
```

这一次，我们必须使用寄存器的“字节版本”名字，
再配合 `movb` 指令来只移动一个字节。

幸运的是，`cgloadglob()` 已经把 `P_CHAR` 变量完成了扩宽。
所以我们的新 `cgwiden()` 函数目前长这样：

```c
// Widen the value in the register from the old
// to the new type, and return a register with
// this new value
int cgwiden(int r, int oldtype, int newtype) {
  // Nothing to do
  return (r);
}
```

## 通用代码生成器的变化

有了上面的基础，
`gen.c` 中通用代码生成器其实只需要少量修改：

  + `cgloadglob()` 和 `cgstorglob()` 现在接收的是符号槽位号，
    而不再是符号名字
  + 同样地，`genglobsym()` 现在接收槽位号，
    再把它传给 `cgglobsym()`

唯一一个较大的改动，是处理新的 `A_WIDEN` AST 节点类型。
在 x86-64 上我们实际上不需要这个节点
（因为 `cgwiden()` 目前什么都不做），
但它是为其他硬件平台预留的：

```c
    case A_WIDEN:
      // Widen the child's type to the parent's type
      return (cgwiden(leftreg, n->left->type, n->type));
```

## 测试新的类型改动

这是我的测试输入文件 `tests/input10`：

```c
void main()
{
  int i; char j;

  j= 20; print j;
  i= 10; print i;

  for (i= 1;   i <= 5; i= i + 1) { print i; }
  for (j= 253; j != 2; j= j + 1) { print j; }
}
```

我在这里验证了：
我们可以给 `char` 和 `int` 赋值并打印它们；
同时也验证了对 `char` 变量来说，
数值序列会发生溢出：253、254、255、0、1、2……

```
$ make test
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
   stmt.c sym.c tree.c types.c
./comp1 tests/input10
cc -o out out.s
./out
20
10
1
2
3
4
5
253
254
255
0
1
```

下面来看一部分生成出来的汇编代码：

```
        .comm   i,8,8                   # Eight byte i storage
        .comm   j,1,1                   # One   byte j storage
        ...
        movq    $20, %r8
        movb    %r8b, j(%rip)           # j= 20
        movzbq  j(%rip), %r8
        movq    %r8, %rdi               # print j
        call    printint

        movq    $253, %r8
        movb    %r8b, j(%rip)           # j= 253
L3:
        movzbq  j(%rip), %r8
```

## 总结与下一步

类型系统的第一步已经搭起来了。
下一部分我们会继续推进，
同时把函数返回值也纳入进来。 [下一步](../13_Functions_pt2/Readme.md)
