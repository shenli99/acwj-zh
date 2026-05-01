# 第 13 部分：函数，第 2 部分

在编译器编写之旅的这一部分中，
我想加入函数调用以及返回值能力。具体来说：

 + 定义函数，这一点我们已经有了
 + 调用一个函数，并给它传入一个值；目前这个值暂时还不会被函数真正使用
 + 从函数中返回一个值
 + 既能把函数调用当成语句，也能把它当成表达式
 + 保证 `void` 函数绝不返回值，而非 `void` 函数必须返回值

我刚刚把这一套做通了。
结果发现我大部分时间其实都花在处理类型问题上。
下面开始记录。

## 新关键字与 token

到目前为止，编译器里一直把 `int` 当成 8 字节（64 位）来处理，
但我意识到 Gcc 实际上把 `int` 当作 4 字节（32 位）。
因此我决定引入 `long` 类型。
所以现在：

  + `char` 宽 1 字节
  + `int` 宽 4 字节（32 位）
  + `long` 宽 8 字节（64 位）

此外，我们还需要支持 `return`，
于是新增了关键字 `long` 和 `return`，
以及对应的 token：`T_LONG` 和 `T_RETURN`。

## 解析函数调用

目前，我给函数调用使用的 BNF 语法是：

```
  function_call: identifier '(' expression ')'   ;
```

函数名后面跟一对括号，
括号中必须有且仅有一个参数。
而我希望这种形式既可以作为表达式使用，
也可以单独作为一条语句使用。

所以先从函数调用解析器开始，
也就是 `expr.c` 中的 `funccall()`。
当这个函数被调用时，
标识符已经被扫描出来了，
而函数名保存在全局变量 `Text` 中：

```c
// Parse a function call with a single expression
// argument and return its AST
struct ASTnode *funccall(void) {
  struct ASTnode *tree;
  int id;

  // Check that the identifier has been defined,
  // then make a leaf node for it. XXX Add structural type test
  if ((id = findglob(Text)) == -1) {
    fatals("Undeclared function", Text);
  }
  // Get the '('
  lparen();

  // Parse the following expression
  tree = binexpr(0);

  // Build the function call AST node. Store the
  // function's return type as this node's type.
  // Also record the function's symbol-id
  tree = mkastunary(A_FUNCCALL, Gsym[id].type, tree, id);

  // Get the ')'
  rparen();
  return (tree);
}
```

我还留了一个提醒注释：*Add structural type test*。
因为函数或变量在声明时，
符号表里都会记录结构类型 `S_FUNCTION` 与 `S_VARIABLE`。
这里我之后还应该补上代码，
确认这个标识符真的就是一个 `S_FUNCTION`。

这里我们构建了一个新的单目 AST 节点 `A_FUNCCALL`。
它的孩子就是作为参数传入的那个单一表达式。
同时我们还会在节点中记录函数的符号编号，
以及函数的返回类型。

## 但我不想要刚刚那个 token 了！

这里会出现一个解析问题。
我们必须区分下面这两种情况：

```
   x= fred + jim;
   x= fred(5) + jim;
```

为了分辨它们，
我们必须向前多看一个 token，看看后面是不是 `'('`。
如果是，那它就是一次函数调用。
但这样一来，我们又会丢掉刚刚读出来的那个 token。

为了解决这个问题，
我修改了扫描器，
让它支持把一个“不想要的 token”放回去：
这样下一次读取 token 时，
它会优先返回这个被退回的 token，
而不是重新扫描新 token。
`scan.c` 中的新代码如下：

```c
// A pointer to a rejected token
static struct token *Rejtoken = NULL;

// Reject the token that we just scanned
void reject_token(struct token *t) {
  if (Rejtoken != NULL)
    fatal("Can't reject token twice");
  Rejtoken = t;
}

// Scan and return the next token found in the input.
// Return 1 if token valid, 0 if no tokens left.
int scan(struct token *t) {
  int c, tokentype;

  // If we have any rejected token, return it
  if (Rejtoken != NULL) {
    t = Rejtoken;
    Rejtoken = NULL;
    return (1);
  }

  // Continue on with the normal scanning
  ...
}
```

## 把函数调用当成表达式

现在我们终于能来看：
在 `expr.c` 的哪里区分“变量名”和“函数调用”。
答案就在 `primary()` 中。
新的代码是：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;

  switch (Token.token) {
    ...
    case T_IDENT:
      // This could be a variable or a function call.
      // Scan in the next token to find out
      scan(&Token);

      // It's a '(', so a function call
      if (Token.token == T_LPAREN)
        return (funccall());

      // Not a function call, so reject the new token
      reject_token(&Token);

      // Continue on with normal variable parsing
      ...
}
```

## 把函数调用当成语句

当我们尝试把函数调用写成一条语句时，
本质上会遇到完全相同的问题。
因为此时我们必须区分：

```
  fred = 2;
  fred(18);
```

因此 `stmt.c` 中新的语句解析代码和上面非常相似：

```c
// Parse an assignment statement and return its AST
static struct ASTnode *assignment_statement(void) {
  struct ASTnode *left, *right, *tree;
  int lefttype, righttype;
  int id;

  // Ensure we have an identifier
  ident();

  // This could be a variable or a function call.
  // If next token is '(', it's a function call
  if (Token.token == T_LPAREN)
    return (funccall());

  // Not a function call, on with an assignment then!
  ...
}
```

这里我们其实不需要把“不想要的 token”再 reject 回去，
因为这里后面*必然*只能是 `'='` 或 `'('`，
所以解析器可以直接按这个假设写下去。

## 解析 `return` 语句

按照 BNF，
我们的 `return` 语句长这样：

```
  return_statement: 'return' '(' expression ')'  ;
```

它的语法解析其实很简单：
读 `'return'`、读 `'('`、调用 `binexpr()`、读 `')'`，完事。
真正困难的部分是：
要检查类型是否匹配，
以及当前函数到底允不允许 `return`。

某种意义上，我们得知道：
当我们在解析一个 `return` 语句时，
当前到底身处哪个函数中。
因此我在 `data.h` 中增加了一个全局变量：

```c
extern_ int Functionid;         // Symbol id of the current function
```

然后在 `decl.c` 的 `function_declaration()` 中设置它：

```c
struct ASTnode *function_declaration(void) {
  ...
  // Add the function to the symbol table
  // and set the Functionid global
  nameslot = addglob(Text, type, S_FUNCTION, endlabel);
  Functionid = nameslot;
  ...
}
```

这样一来，每次进入函数声明解析时，
我们都知道自己当前对应的是哪个函数。
有了这个信息，
就可以回到 `return` 语句的语法与语义检查上了。
下面是 `stmt.c` 中新的 `return_statement()`：

```c
// Parse a return statement and return its AST
static struct ASTnode *return_statement(void) {
  struct ASTnode *tree;
  int returntype, functype;

  // Can't return a value if function returns P_VOID
  if (Gsym[Functionid].type == P_VOID)
    fatal("Can't return from a void function");

  // Ensure we have 'return' '('
  match(T_RETURN, "return");
  lparen();

  // Parse the following expression
  tree = binexpr(0);

  // Ensure this is compatible with the function's type
  returntype = tree->type;
  functype = Gsym[Functionid].type;
  if (!type_compatible(&returntype, &functype, 1))
    fatal("Incompatible types");

  // Widen the left if required.
  if (returntype)
    tree = mkastunary(returntype, functype, tree, 0);

  // Add on the A_RETURN node
  tree = mkastunary(A_RETURN, P_NONE, tree, 0);

  // Get the ')'
  rparen();
  return (tree);
}
```

这里我们新增了一个 `A_RETURN` AST 节点，
它的孩子就是要返回的表达式子树。
我们使用 `type_compatible()` 来确认这个表达式是否与函数返回类型兼容，
并在必要时执行扩宽。

最后，我们还要检查当前函数是不是被声明为 `void`。
如果是，那么在这个函数里就根本不允许 `return` 一个值。

## 重新审视类型

在上一部分里，我引入了 `type_compatible()`，
并说过自己还想重构它。
现在随着 `long` 类型的加入，
这件事已经变成了必要工作。
下面是 `types.c` 中的新版本。
如果你愿意的话，
可以回头对照上一部分的说明一起看。

```c
// Given two primitive types,
// return true if they are compatible,
// false otherwise. Also return either
// zero or an A_WIDEN operation if one
// has to be widened to match the other.
// If onlyright is true, only widen left to right.
int type_compatible(int *left, int *right, int onlyright) {
  int leftsize, rightsize;

  // Same types, they are compatible
  if (*left == *right) { *left = *right = 0; return (1); }
  // Get the sizes for each type
  leftsize = genprimsize(*left);
  rightsize = genprimsize(*right);

  // Types with zero size are not
  // not compatible with anything
  if ((leftsize == 0) || (rightsize == 0)) return (0);

  // Widen types as required
  if (leftsize < rightsize) { *left = A_WIDEN; *right = 0; return (1);
  }
  if (rightsize < leftsize) {
    if (onlyright) return (0);
    *left = 0; *right = A_WIDEN; return (1);
  }
  // Anything remaining is the same size
  // and thus compatible
  *left = *right = 0;
  return (1);
}
```

我现在通过通用代码生成器里的 `genprimsize()`，
再调用 `cg.c` 中的 `cgprimsize()`，
来获得各种类型的大小：

```c
// Array of type sizes in P_XXX order.
// 0 means no size. P_NONE, P_VOID, P_CHAR, P_INT, P_LONG
static int psize[] = { 0,       0,      1,     4,     8 };

// Given a P_XXX type value, return the
// size of a primitive type in bytes.
int cgprimsize(int type) {
  // Check the type is valid
  if (type < P_NONE || type > P_LONG)
    fatal("Bad type in cgprimsize()");
  return (psize[type]);
}
```

这样一来，类型大小就变成了平台相关的内容；
其他平台完全可以选择不同的类型大小。
这大概也意味着我之前那段“把 `P_INTLIT` 判成 `char` 而不是 `int`”的逻辑，
以后也得重构：

```c
  if ((Token.intvalue) >= 0 && (Token.intvalue < 256))
```

## 确保非 `void` 函数一定返回值

前面我们刚刚确保了 `void` 函数不能返回值。
那现在又该如何保证：非 `void` 函数一定*会*返回一个值？

为了做到这一点，
我们必须保证函数中的最后一条语句就是 `return` 语句。

在 `decl.c` 中 `function_declaration()` 的底部，
我现在加上了下面这段逻辑：

```c
  struct ASTnode *tree, *finalstmt;
  ...
  // If the function type isn't P_VOID, check that
  // the last AST operation in the compound statement
  // was a return statement
  if (type != P_VOID) {
    finalstmt = (tree->op == A_GLUE) ? tree->right : tree;
    if (finalstmt == NULL || finalstmt->op != A_RETURN)
      fatal("No return for function with non-void type");
  }
```

这里的麻烦在于：
如果函数体里恰好只有一条语句，
那么树中就不会有 `A_GLUE` 节点，
而那棵树本身就是这条语句。

做到这一步之后，
我们已经可以：

  + 声明函数，保存函数类型，并记录当前正在解析哪个函数
  + 调用函数（无论作为表达式还是语句），并传入一个参数
  + 从非 `void` 函数中返回值，并强制要求非 `void` 函数最后一条语句必须是 `return`
  + 检查并扩宽返回表达式，使其匹配函数类型定义

此时我们的 AST 已经多了 `A_RETURN` 和 `A_FUNCCALL` 节点，
分别用于表示返回语句和函数调用。
下面再看看它们如何生成汇编。

## 为什么只支持一个参数？

你这时可能会问：
既然这个参数目前在函数体里根本还用不到，
为什么非要先支持“单参数函数调用”？

答案是：我想把语言中的 `print x;` 语句，
替换成一个真正的函数调用：`printint(x);`。
为此，我们可以先把一个真实的 C 函数 `printint()` 编译出来，
再和编译器生成的汇编输出链接到一起。

## 新 AST 节点的代码生成

`gen.c` 中 `genAST()` 的新代码其实不多：

```c
    case A_RETURN:
      cgreturn(leftreg, Functionid);
      return (NOREG);
    case A_FUNCCALL:
      return (cgcall(leftreg, n->v.id));
```

`A_RETURN` 不是表达式，
因此它不会再返回一个值。
而 `A_FUNCCALL` 当然是表达式。

## x86-64 输出的变化

所有新增的代码生成工作，
基本都集中在平台专用代码生成器 `cg.c` 里。
下面逐项来看。

### 新类型

首先，我们现在有 `char`、`int` 和 `long` 三种类型，
而 x86-64 要求我们在不同类型下使用不同的寄存器名字：

```c
// List of available registers and their names.
static int freereg[4];
static char *reglist[4] = { "%r8", "%r9", "%r10", "%r11" };
static char *breglist[4] = { "%r8b", "%r9b", "%r10b", "%r11b" };
static char *dreglist[4] = { "%r8d", "%r9d", "%r10d", "%r11d" }
```

### 定义、加载和保存变量

变量现在有三种可能的类型。
因此生成出来的代码也必须反映这一点。
下面是修改后的函数：

```c
// Generate a global symbol
void cgglobsym(int id) {
  int typesize;
  // Get the size of the type
  typesize = cgprimsize(Gsym[id].type);

  fprintf(Outfile, "\t.comm\t%s,%d,%d\n", Gsym[id].name, typesize, typesize);
}

// Load a value from a variable into a register.
// Return the number of the register
int cgloadglob(int id) {
  // Get a new register
  int r = alloc_register();

  // Print out the code to initialise it
  switch (Gsym[id].type) {
    case P_CHAR:
      fprintf(Outfile, "\tmovzbq\t%s(\%%rip), %s\n", Gsym[id].name,
              reglist[r]);
      break;
    case P_INT:
      fprintf(Outfile, "\tmovzbl\t%s(\%%rip), %s\n", Gsym[id].name,
              reglist[r]);
      break;
    case P_LONG:
      fprintf(Outfile, "\tmovq\t%s(\%%rip), %s\n", Gsym[id].name, reglist[r]);
      break;
    default:
      fatald("Bad type in cgloadglob:", Gsym[id].type);
  }
  return (r);
}

// Store a register's value into a variable
int cgstorglob(int r, int id) {
  switch (Gsym[id].type) {
    case P_CHAR:
      fprintf(Outfile, "\tmovb\t%s, %s(\%%rip)\n", breglist[r],
              Gsym[id].name);
      break;
    case P_INT:
      fprintf(Outfile, "\tmovl\t%s, %s(\%%rip)\n", dreglist[r],
              Gsym[id].name);
      break;
    case P_LONG:
      fprintf(Outfile, "\tmovq\t%s, %s(\%%rip)\n", reglist[r], Gsym[id].name);
      break;
    default:
      fatald("Bad type in cgloadglob:", Gsym[id].type);
  }
  return (r);
}
```

### 函数调用

要调用一个带单参数的函数，
我们必须把保存参数值的寄存器内容复制到 `%rdi` 中。
函数返回时，
还要把 `%rax` 里的返回值复制到新的目标寄存器里：

```c
// Call a function with one argument from the given register
// Return the register with the result
int cgcall(int r, int id) {
  // Get a new register
  int outr = alloc_register();
  fprintf(Outfile, "\tmovq\t%s, %%rdi\n", reglist[r]);
  fprintf(Outfile, "\tcall\t%s\n", Gsym[id].name);
  fprintf(Outfile, "\tmovq\t%%rax, %s\n", reglist[outr]);
  free_register(r);
  return (outr);
}
```

### 函数返回

为了能够从函数执行过程中的任意位置返回，
我们需要跳转到函数底部的某个统一标签。
我在 `function_declaration()` 里加入了生成该标签并把它存进符号表的逻辑。
而由于返回值必须通过 `%rax` 离开函数，
因此在跳到结束标签之前，
我们先把结果复制到 `%rax`：

```c
// Generate code to return a value from a function
void cgreturn(int reg, int id) {
  // Generate code depending on the function's type
  switch (Gsym[id].type) {
    case P_CHAR:
      fprintf(Outfile, "\tmovzbl\t%s, %%eax\n", breglist[reg]);
      break;
    case P_INT:
      fprintf(Outfile, "\tmovl\t%s, %%eax\n", dreglist[reg]);
      break;
    case P_LONG:
      fprintf(Outfile, "\tmovq\t%s, %%rax\n", reglist[reg]);
      break;
    default:
      fatald("Bad function type in cgreturn:", Gsym[id].type);
  }
  cgjump(Gsym[id].endlabel);
}
```

### 函数前导与后导的变化

前导代码没有变化，
但之前我们在返回前会把 `%rax` 设置成 0。
现在这段代码必须删掉：

```c
// Print out a function postamble
void cgfuncpostamble(int id) {
  cglabel(Gsym[id].endlabel);
  fputs("\tpopq %rbp\n" "\tret\n", Outfile);
}
```

### 初始前导代码的变化

到目前为止，
我一直在汇编输出开头手工插入一个汇编版本的 `printint()`。
现在不需要了，
因为我们可以把一个真正的 C 版 `printint()` 编译出来，
再与编译器输出链接。

## 测试这些改动

现在有了一个新的测试程序 `tests/input14`：

```c
int fred() {
  return(20);
}

void main() {
  int result;
  printint(10);
  result= fred(15);
  printint(result);
  printint(fred(15)+10);
  return(0);
}
```

它会先打印 10，
然后调用 `fred()`，后者返回 20，于是我们再把 20 打印出来。
最后，再调用一次 `fred()`，
把返回值加上 10，再打印 30。
这就同时展示了：
单参数函数调用、函数返回值，
以及函数调用作为表达式参与运算。
下面是测试结果：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
    stmt.c sym.c tree.c types.c
./comp1 tests/input14
cc -o out out.s lib/printint.c
./out; true
10
20
30
```

注意，我们把汇编输出和 `lib/printint.c` 一起链接了：

```c
#include <stdio.h>
void printint(long x) {
  printf("%ld\n", x);
}
```

## 现在几乎已经像 C 了

做完这个改动后，我们已经可以这样干：

```
$ cat lib/printint.c tests/input14 > input14.c
$ cc -o out input14.c
$ ./out 
10
20
30
```

换句话说，
我们的语言已经足够接近 C 的一个子集，
以至于可以和其他 C 函数拼在一起，交给普通 C 编译器来生成可执行程序。
这非常不错。

## 总结与下一步

我们刚刚加入了一个简单版本的函数调用、函数返回，
以及一种新的数据类型。
正如我预料的那样，
这并不轻松，但整体改动我觉得还是比较合理的。

在编译器编写之旅的下一部分中，
我们会把编译器移植到新的硬件平台上：
ARM CPU，也就是 Raspberry Pi 上使用的那种。 [下一步](../14_ARM_Platform/Readme.md)
