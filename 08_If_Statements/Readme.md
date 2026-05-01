# 第 8 部分：`if` 语句

现在我们已经可以比较值了，
是时候给语言加入 `if` 语句了。
所以先来看看 `if` 语句的一般语法，以及它通常如何被转换成汇编语言。

## `if` 的语法

`if` 语句的语法是：

```
  if (condition is true) 
    perform this first block of code
  else
    perform this other block of code
```

那么，这种结构通常会怎样被转换成汇编语言呢？
答案是：我们会做“相反的比较”，如果相反条件为真就跳转：

```
       perform the opposite comparison
       jump to L1 if true
       perform the first block of code
       jump to L2
L1:
       perform the other block of code
L2:
   
```

其中 `L1` 和 `L2` 是汇编标签。

## 在我们的编译器里生成这类汇编

现在，我们生成比较表达式时代码的行为是：
根据比较结果设置一个寄存器，例如：

```
   int x; x= 7 < 9;         From input04
```

会变成：

```
        movq    $7, %r8
        movq    $9, %r9
        cmpq    %r9, %r8
        setl    %r9b        Set if less than 
        andq    $255,%r9
```

但对于 `if` 语句，我们需要在“相反的比较结果成立时跳转”：

```
   if (7 < 9) 
```

应该变成：

```
        movq    $7, %r8
        movq    $9, %r9
        cmpq    %r9, %r8
        jge     L1         Jump if greater then or equal to
        ....
L1:
```

所以，在这一部分的旅程里，我实现了 `if` 语句。
由于这是一个正在演化的项目，
我在过程中确实推翻并重构了一些已有实现。
我会尽量把这些变化和新增内容都一并说明清楚。

## 新 token 与悬空 `else`

我们的语言现在需要一批新的 token。
同时，我目前也想先避开
[dangling else problem](https://en.wikipedia.org/wiki/Dangling_else)。
为此，我修改了语法，
要求所有语句块都必须用花括号 `'{' ... '}'` 包起来；
我把这种分组叫做“复合语句（compound statement）”。
此外，还需要用括号 `'(' ... ')'` 包住 `if` 条件表达式，
并加入关键字 `if` 与 `else`。
因此新增的 token 如下（位于 `defs.h`）：

```c
  T_LBRACE, T_RBRACE, T_LPAREN, T_RPAREN,
  // Keywords
  ..., T_IF, T_ELSE
```

## 扫描这些 token

那些单字符 token 的扫描方式都很直接，
这里就不展开了。
关键字的处理也很容易理解，
不过我还是把 `scan.c` 中 `keyword()` 的扫描代码贴出来：

```c
  switch (*s) {
    case 'e':
      if (!strcmp(s, "else"))
        return (T_ELSE);
      break;
    case 'i':
      if (!strcmp(s, "if"))
        return (T_IF);
      if (!strcmp(s, "int"))
        return (T_INT);
      break;
    case 'p':
      if (!strcmp(s, "print"))
        return (T_PRINT);
      break;
  }
```

## 新的 BNF 语法

我们的语法现在开始变大了，
所以我对它做了一点重写：

```
 compound_statement: '{' '}'          // empty, i.e. no statement
      |      '{' statement '}'
      |      '{' statement statements '}'
      ;

 statement: print_statement
      |     declaration
      |     assignment_statement
      |     if_statement
      ;

 print_statement: 'print' expression ';'  ;

 declaration: 'int' identifier ';'  ;

 assignment_statement: identifier '=' expression ';'   ;

 if_statement: if_head
      |        if_head 'else' compound_statement
      ;

 if_head: 'if' '(' true_false_expression ')' compound_statement  ;

 identifier: T_IDENT ;
```

这里我先省略了 `true_false_expression` 的定义，
等我们后面再加一些运算符之后，我会把它补完整。

注意 `if` 语句的语法：
它要么只是一个 `if_head`（没有 `else`），
要么是一个 `if_head` 后面再跟着 `else` 和一个 `compound_statement`。

我把不同类型的语句都拆成了各自独立的非终结符名字。
另外，之前的 `statements` 非终结符，
现在被并入了 `compound_statement`，
而且这意味着语句必须被包在 `'{' ... '}'` 中。

这也就是说，
`if` 头部里的 `compound_statement` 是一组被 `'{' ... '}'` 包住的语句，
`else` 后面的 `compound_statement` 也同样如此。
因此，如果我们写嵌套 `if`，
就必须长成这样：

```
  if (condition1 is true) {
    if (condition2 is true) {
      statements;
    } else {
      statements;
    }
  } else {
    statements;
  }
```

这样就不会再有“到底某个 `else` 属于哪个 `if`”的歧义了，
也就解决了悬空 `else` 问题。
以后我会把 `'{' ... '}'` 做成可选的。

## 解析复合语句

原来的 `void statements()` 现在变成了 `compound_statement()`，
代码如下：

```c
// Parse a compound statement
// and return its AST
struct ASTnode *compound_statement(void) {
  struct ASTnode *left = NULL;
  struct ASTnode *tree;

  // Require a left curly bracket
  lbrace();

  while (1) {
    switch (Token.token) {
      case T_PRINT:
        tree = print_statement();
        break;
      case T_INT:
        var_declaration();
        tree = NULL;            // No AST generated here
        break;
      case T_IDENT:
        tree = assignment_statement();
        break;
      case T_IF:
        tree = if_statement();
        break;
    case T_RBRACE:
        // When we hit a right curly bracket,
        // skip past it and return the AST
        rbrace();
        return (left);
      default:
        fatald("Syntax error, token", Token.token);
    }

    // For each new tree, either save it in left
    // if left is empty, or glue the left and the
    // new tree together
    if (tree) {
      if (left == NULL)
        left = tree;
      else
        left = mkastnode(A_GLUE, left, NULL, tree, 0);
    }
  }
```

首先要注意，这段代码强制要求解析器在复合语句开头通过 `lbrace()` 匹配 `'{'`，
并且只有在结尾通过 `rbrace()` 匹配到 `'}'` 时才能退出。

其次，请注意 `print_statement()`、`assignment_statement()` 和
`if_statement()` 都会返回一棵 AST，
`compound_statement()` 本身也是如此。

在旧代码里，`print_statement()` 会自己调用 `genAST()` 求值表达式，
随后再调用 `genprintint()`。
类似地，`assignment_statement()` 也会自己调用 `genAST()`
完成赋值。

这意味着，有些 AST 在这里生成，有些 AST 在那里生成。
于是，把整段输入统一构造成一棵 AST，
再只调用一次 `genAST()` 来生成汇编代码，
就变得更合理了。

这并不是唯一做法。
例如 SubC 只为表达式生成 AST。
对于语言结构部分，比如语句，
SubC 会像我在旧版本编译器里那样，
直接对代码生成器发出特定调用。

但我现在决定：先为整个输入构建一棵完整 AST。
等解析完输入之后，再从这一棵 AST 统一生成汇编输出。

后面我大概会改成“每个函数生成一棵 AST”。
不过那是以后的事。

## 解析 `if` 语法

由于我们用的是递归下降解析器，
解析 `if` 语句本身并不算太难：

```c
// Parse an IF statement including
// any optional ELSE clause
// and return its AST
struct ASTnode *if_statement(void) {
  struct ASTnode *condAST, *trueAST, *falseAST = NULL;

  // Ensure we have 'if' '('
  match(T_IF, "if");
  lparen();

  // Parse the following expression
  // and the ')' following. Ensure
  // the tree's operation is a comparison.
  condAST = binexpr(0);

  if (condAST->op < A_EQ || condAST->op > A_GE)
    fatal("Bad comparison operator");
  rparen();

  // Get the AST for the compound statement
  trueAST = compound_statement();

  // If we have an 'else', skip it
  // and get the AST for the compound statement
  if (Token.token == T_ELSE) {
    scan(&Token);
    falseAST = compound_statement();
  }
  // Build and return the AST for this statement
  return (mkastnode(A_IF, condAST, trueAST, falseAST, 0));
}
```

目前我还不想处理像 `if (x-2)` 这样的输入，
所以我要求 `binexpr()` 返回的二元表达式，
其根节点必须是六种比较运算符之一：
`A_EQ`、`A_NE`、`A_LT`、`A_GT`、`A_LE` 或 `A_GE`。

## 第三个孩子节点

前面我差点偷偷塞过去一个变化而没解释清楚。
在 `if_statement()` 最后一行里，
我构造 AST 节点时写的是：

```c
   mkastnode(A_IF, condAST, trueAST, falseAST, 0);
```

这里有*三棵* AST 子树！这是什么情况？
正如你看到的，`if` 语句现在会有三个孩子：

  + 一棵用于计算条件的子树
  + `if` 后面紧跟的复合语句
  + 可选的 `else` 后复合语句

因此，AST 节点结构现在也需要支持三个孩子
（定义于 `defs.h`）：

```c
// AST node types.
enum {
  ...
  A_GLUE, A_IF
};

// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  struct ASTnode *left;         // Left, middle and right child trees
  struct ASTnode *mid;
  struct ASTnode *right;
  union {
    int intvalue;               // For A_INTLIT, the integer value
    int id;                     // For A_IDENT, the symbol slot number
  } v;
};
```

于是，一棵 `A_IF` 树会长成这样：

```
                      IF
                    / |  \
                   /  |   \
                  /   |    \
                 /    |     \
                /     |      \
               /      |       \
      condition   statements   statements
```

## `A_GLUE` AST 节点

现在还有一个新的 `A_GLUE` AST 节点类型。
它是干什么用的？
因为我们现在要为一整个由多条语句组成的输入构建单棵 AST，
就需要一种把这些语句“粘”在一起的方式。

回顾一下 `compound_statement()` 循环末尾的代码：

```c
      if (left != NULL)
        left = mkastnode(A_GLUE, left, NULL, tree, 0);
```

每当我们得到一棵新的子树，
就把它粘接到当前已有的树上。
所以，对下面这样一串语句：

```
    stmt1;
    stmt2;
    stmt3;
    stmt4;
```

最终会得到：

```
             A_GLUE
              /  \
          A_GLUE stmt4
            /  \
        A_GLUE stmt3
          /  \
      stmt1  stmt2
```

由于我们遍历树时仍然是按从左到右的深度优先顺序，
所以生成出的汇编代码顺序依然是正确的。

## 通用代码生成器

既然 AST 节点现在有了多个孩子，
我们的通用代码生成器也会变得稍微复杂一点。
此外，对于比较运算符，
我们还需要知道当前比较是不是作为 `if` 语句的一部分：
如果是，那就要在“相反比较成立时跳转”；
如果不是，那就是普通表达式，需要把寄存器设为 1 或 0。

为此，我修改了 `genAST()`，
让它可以接收“父 AST 节点的操作类型”：

```c
// Given an AST, the register (if any) that holds
// the previous rvalue, and the AST op of the parent,
// generate assembly code recursively.
// Return the register id with the tree's final value
int genAST(struct ASTnode *n, int reg, int parentASTop) {
   ...
}
```

### 处理特定的 AST 节点

现在 `genAST()` 必须首先处理一些特殊 AST 节点：

```c
  // We now have specific AST node handling at the top
  switch (n->op) {
    case A_IF:
      return (genIFAST(n));
    case A_GLUE:
      // Do each child statement, and free the
      // registers after each child
      genAST(n->left, NOREG, n->op);
      genfreeregs();
      genAST(n->right, NOREG, n->op);
      genfreeregs();
      return (NOREG);
  }
```

如果这里没有直接返回，
后面才会继续进入普通二元运算节点的处理逻辑。
其中有一个例外：比较节点：

```c
    case A_EQ:
    case A_NE:
    case A_LT:
    case A_GT:
    case A_LE:
    case A_GE:
      // If the parent AST node is an A_IF, generate a compare
      // followed by a jump. Otherwise, compare registers and
      // set one to 1 or 0 based on the comparison.
      if (parentASTop == A_IF)
        return (cgcompare_and_jump(n->op, leftreg, rightreg, reg));
      else
        return (cgcompare_and_set(n->op, leftreg, rightreg));
```

下面我会再解释新的 `cgcompare_and_jump()` 和
`cgcompare_and_set()`。

### 生成 `if` 的汇编代码

我们用一个专门函数来处理 `A_IF` 节点，
同时还加了一个函数来生成新的标签编号：

```c
// Generate and return a new label number
static int label(void) {
  static int id = 1;
  return (id++);
}

// Generate the code for an IF statement
// and an optional ELSE clause
static int genIFAST(struct ASTnode *n) {
  int Lfalse, Lend;

  // Generate two labels: one for the
  // false compound statement, and one
  // for the end of the overall IF statement.
  // When there is no ELSE clause, Lfalse _is_
  // the ending label!
  Lfalse = label();
  if (n->right)
    Lend = label();

  // Generate the condition code followed
  // by a zero jump to the false label.
  // We cheat by sending the Lfalse label as a register.
  genAST(n->left, Lfalse, n->op);
  genfreeregs();

  // Generate the true compound statement
  genAST(n->mid, NOREG, n->op);
  genfreeregs();

  // If there is an optional ELSE clause,
  // generate the jump to skip to the end
  if (n->right)
    cgjump(Lend);

  // Now the false label
  cglabel(Lfalse);

  // Optional ELSE clause: generate the
  // false compound statement and the
  // end label
  if (n->right) {
    genAST(n->right, NOREG, n->op);
    genfreeregs();
    cglabel(Lend);
  }

  return (NOREG);
}
```

本质上，这段代码做的事情就是：

```c
  genAST(n->left, Lfalse, n->op);       // Condition and jump to Lfalse
  genAST(n->mid, NOREG, n->op);         // Statements after 'if'
  cgjump(Lend);                         // Jump to Lend
  cglabel(Lfalse);                      // Lfalse: label
  genAST(n->right, NOREG, n->op);       // Statements after 'else'
  cglabel(Lend);                        // Lend: label
```

## x86-64 代码生成函数

于是我们现在就多了几个新的 x86-64 代码生成函数。
其中有些会替换上一部分中写的那六个 `cgXXX()` 比较函数。

对于普通比较函数，
我们现在直接传入 AST 操作类型，
用它来选出对应的 x86-64 `set` 指令：

```c
// List of comparison instructions,
// in AST order: A_EQ, A_NE, A_LT, A_GT, A_LE, A_GE
static char *cmplist[] =
  { "sete", "setne", "setl", "setg", "setle", "setge" };

// Compare two registers and set if true.
int cgcompare_and_set(int ASTop, int r1, int r2) {

  // Check the range of the AST operation
  if (ASTop < A_EQ || ASTop > A_GE)
    fatal("Bad ASTop in cgcompare_and_set()");

  fprintf(Outfile, "\tcmpq\t%s, %s\n", reglist[r2], reglist[r1]);
  fprintf(Outfile, "\t%s\t%s\n", cmplist[ASTop - A_EQ], breglist[r2]);
  fprintf(Outfile, "\tmovzbq\t%s, %s\n", breglist[r2], reglist[r2]);
  free_register(r1);
  return (r2);
}
```

我还发现 x86-64 有一条 `movzbq` 指令，
它可以把某个寄存器的最低字节取出来，
再零扩展成 64 位寄存器。
于是我现在改用它，
而不再像以前那样用 `and $255`。

我们还需要两个函数，
一个生成标签，一个跳到标签：

```c
// Generate a label
void cglabel(int l) {
  fprintf(Outfile, "L%d:\n", l);
}

// Generate a jump to a label
void cgjump(int l) {
  fprintf(Outfile, "\tjmp\tL%d\n", l);
}
```

最后，我们还需要一个函数，
能在做比较后，根据“相反的比较结果”为真来跳转。
所以我们根据 AST 比较节点类型，映射到相反的比较指令：

```c
// List of inverted jump instructions,
// in AST order: A_EQ, A_NE, A_LT, A_GT, A_LE, A_GE
static char *invcmplist[] = { "jne", "je", "jge", "jle", "jg", "jl" };

// Compare two registers and jump if false.
int cgcompare_and_jump(int ASTop, int r1, int r2, int label) {

  // Check the range of the AST operation
  if (ASTop < A_EQ || ASTop > A_GE)
    fatal("Bad ASTop in cgcompare_and_set()");

  fprintf(Outfile, "\tcmpq\t%s, %s\n", reglist[r2], reglist[r1]);
  fprintf(Outfile, "\t%s\tL%d\n", invcmplist[ASTop - A_EQ], label);
  freeall_registers();
  return (NOREG);
}
```

## 测试 `if` 语句

执行一次 `make test`，
它会编译 `input05`：

```c
{
  int i; int j;
  i=6; j=12;
  if (i < j) {
    print i;
  } else {
    print j;
  }
}
```

下面是生成出来的汇编输出：

```
        movq    $6, %r8
        movq    %r8, i(%rip)    # i=6;
        movq    $12, %r8
        movq    %r8, j(%rip)    # j=12;
        movq    i(%rip), %r8
        movq    j(%rip), %r9
        cmpq    %r9, %r8        # Compare %r8-%r9, i.e. i-j
        jge     L1              # Jump to L1 if i >= j
        movq    i(%rip), %r8
        movq    %r8, %rdi       # print i;
        call    printint
        jmp     L2              # Skip the else code
L1:
        movq    j(%rip), %r8
        movq    %r8, %rdi       # print j;
        call    printint
L2:
```

当然，`make test` 的结果会告诉我们：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c
      scan.c stmt.c sym.c tree.c
./comp1 input05
cc -o out out.s
./out
6                   # As 6 is less than 12
```

## 总结与下一步

我们已经把第一种控制结构 `if` 语句加入了语言。
在这个过程中，我确实不得不重写一些已有实现；
而且考虑到我脑子里还没有一份完整的总架构图，
以后大概还得继续重写别的部分。

这一部分真正有意思的地方在于：
为了实现 `if` 决策，
我们必须执行“和普通比较运算相反的比较跳转”。
我的做法是，让每个 AST 节点都知道它父节点的类型；
这样比较节点就能判断自己的父节点是不是 `A_IF`。

我知道 Nils Holm 在实现 SubC 时采取了另一种方式，
所以你也应该去看看他的代码，
比较一下同一个问题还可以怎样解决。

在编译器编写之旅的下一部分中，
我们会再加入一种控制结构：`while` 循环。 [下一步](../09_While_Loops/Readme.md)
