# 第 19 部分：数组，第 1 部分

> *我大学一年级的讲师是一位苏格兰人，
  口音非常重。大一第一学期大概到第三或第四周时，
  他上课经常说 “Hurray!”。我花了差不多二十分钟
  才反应过来，他说的其实是 “array”。*

这一部分里，我们开始给编译器加入数组（array）支持。
我先坐下来写了一个小的 C 程序，
看看自己到底应该尝试实现哪些功能：

```c
  int ary[5];               // Array of five int elements
  int *ptr;                 // Pointer to an int

  ary[3]= 63;               // Set ary[3] (lvalue) to 63
  ptr   = ary;              // Point ptr to base of ary
  // ary= ptr;              // error: assignment to expression with array type
  ptr   = &ary[0];          // Also point ptr to base of ary, ary[0] is lvalue
  ptr[4]= 72;               // Use ptr like an array, ptr[4] is an lvalue
```

数组和指针（pointer）很像，
因为无论是指针还是数组，
都可以用 `[ ]` 语法解引用（dereference）到某个具体元素。
我们可以把数组名当作“指针”来用，
把数组基地址存进一个指针变量里；
也可以拿到数组中某个元素的地址。
但有一件事不能做：
不能用一个指针去“覆盖”数组的基地址。
数组的元素是可变的，
但数组的基地址本身不可变。

在这一部分里，我会加入：

 + 固定大小、但没有初始化列表的数组声明
 + 表达式里作为右值（rvalue）的数组下标
 + 赋值语句里作为左值（lvalue）的数组下标

另外，我暂时不会实现多维数组。

## 表达式中的括号

我一直想试一下这样的写法：`*(ptr + 2)`，
它最终应该和 `ptr[2]` 等价。
但我们的表达式目前还不支持括号，
所以现在正是把它补上的时候。

### C 的 BNF 语法

网上有一份
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)，
由 Jeff Lee 在 1985 年写成。
我很喜欢拿它来做参考，
既能给我一些实现思路，
也能帮助我确认自己没有犯太离谱的错误。

这里有一点值得注意：
它并不是直接用“优先级表”来实现 C 里二元表达式运算符的优先级，
而是通过递归定义把优先级关系显式写进语法里。
例如：

```
additive_expression
        : multiplicative_expression
        | additive_expression '+' multiplicative_expression
        | additive_expression '-' multiplicative_expression
        ;
```

这表示：
当我们在解析 `additive_expression` 时，
会继续下降去解析 `multiplicative_expression`，
因此 `'*'` 和 `'/'` 的优先级天然高于 `'+'` 和 `'-'`。

而在整个表达式优先级层级的最顶部，是：

```
primary_expression
        : IDENTIFIER
        | CONSTANT
        | STRING_LITERAL
        | '(' expression ')'
        ;
```

我们已经有一个 `primary()` 函数，
负责识别 `T_INTLIT` 和 `T_IDENT` token，
这和 Jeff Lee 的 C 语法刚好吻合。
因此，把“带括号的表达式”加进来，
最合适的地方就是这里。

我们的语言里本来就已经有 `T_LPAREN` 和 `T_RPAREN` 这两个 token，
所以词法扫描器（lexical scanner）这边完全不用改。

我们只需要稍微修改一下 `primary()`，
额外做这段解析：

```c
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  ...

  switch (Token.token) {
  case T_INTLIT:
  ...
  case T_IDENT:
  ...
  case T_LPAREN:
    // Beginning of a parenthesised expression, skip the '('.
    // Scan in the expression and the right parenthesis
    scan(&Token);
    n = binexpr(0);
    rparen();
    return (n);

    default:
    fatald("Expecting a primary expression, got token", Token.token);
  }

  // Scan in the next token and return the leaf node
  scan(&Token);
  return (n);
}
```

就这些！只需要多加几行代码，
表达式里的括号就支持了。
你会注意到，
我在新代码里显式调用了 `rparen()`，
并且直接 `return`，
而不是跳出 `switch`。
如果离开 `switch` 之后再继续执行，
尾部那句 `scan(&Token);`
就不能严格保证：
当前这个 `')'` 一定是和前面的 `'('` 成对匹配的那个 token。

`test/input19.c` 里有一段测试代码，
专门检查括号是否正常工作：

```c
  a= 2; b= 4; c= 3; d= 2;
  e= (a+b) * (c+d);
  printint(e);
```

它应该输出 30，也就是 `6 * 5` 的结果。

## 符号表的变更

目前我们的符号表里有标量变量（scalar variable，仅保存一个值）
和函数（function）。
现在该把数组也加进去了。
另外，后面我们还会希望通过 `sizeof()` 运算符
拿到每个数组的元素个数。
下面是 `defs.h` 里的修改：

```c
// Structural types
enum {
  S_VARIABLE, S_FUNCTION, S_ARRAY
};

// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  int stype;                    // Structural type for the symbol
  int endlabel;                 // For S_FUNCTIONs, the end label
  int size;                     // Number of elements in the symbol
};
```

暂时我们会把数组当作指针来处理，
因此一个数组的类型就是“指向某种元素的指针”，
例如元素是 `int` 时，
数组类型就视为 “pointer to int”。
同时我们还需要给 `sym.c` 里的 `addglob()` 多加一个参数：

```c
int addglob(char *name, int type, int stype, int endlabel, int size) {
  ...
}
```

## 解析数组声明

目前我只打算支持“带大小的数组声明”。
此时变量声明的 BNF 语法变成：

```
 variable_declaration: type identifier ';'
        | type identifier '[' P_INTLIT ']' ';'
        ;
```

因此，
我们需要在 `decl.c` 的 `var_declaration()` 里
看看下一个 token 是什么，
再决定解析“标量变量声明”还是“数组声明”：

```c
// Parse the declaration of a scalar variable or an array
// with a given size.
// The identifier has been scanned & we have the type
void var_declaration(int type) {
  int id;

  // Text now has the identifier's name.
  // If the next token is a '['
  if (Token.token == T_LBRACKET) {
    // Skip past the '['
    scan(&Token);

    // Check we have an array size
    if (Token.token == T_INTLIT) {
      // Add this as a known array and generate its space in assembly.
      // We treat the array as a pointer to its elements' type
      id = addglob(Text, pointer_to(type), S_ARRAY, 0, Token.intvalue);
      genglobsym(id);
    }

    // Ensure we have a following ']'
    scan(&Token);
    match(T_RBRACKET, "]");
  } else {
    ...      // Previous code
  }
  
    // Get the trailing semicolon
  semi();
}
```

我觉得这段代码相当直接。
后面我们会继续扩展，
给数组声明加上初始化列表（initialisation list）。

## 生成数组存储空间

既然现在已经知道数组大小了，
我们就可以修改 `cgglobsym()`，
让它在汇编里分配对应空间：

```c
void cgglobsym(int id) {
  int typesize;
  // Get the size of the type
  typesize = cgprimsize(Gsym[id].type);

  // Generate the global identity and the label
  fprintf(Outfile, "\t.data\n" "\t.globl\t%s\n", Gsym[id].name);
  fprintf(Outfile, "%s:", Gsym[id].name);

  // Generate the space
  for (int i=0; i < Gsym[id].size; i++) {
    switch(typesize) {
      case 1: fprintf(Outfile, "\t.byte\t0\n"); break;
      case 4: fprintf(Outfile, "\t.long\t0\n"); break;
      case 8: fprintf(Outfile, "\t.quad\t0\n"); break;
      default: fatald("Unknown typesize in cgglobsym: ", typesize);
    }
  }
}
```

有了这段逻辑之后，
我们就能声明这样的数组了：

```c
  char a[10];
  int  b[25];
  long c[100];
```

## 解析数组下标

这一部分里我不想一下子做得太激进。
我只想先让“基础数组下标”在右值和左值两种场景里跑起来。
`test/input20.c` 这个程序就体现了我想实现的功能：

```c
int a;
int b[25];

int main() {
  b[3]= 12; a= b[3];
  printint(a); return(0);
}
```

回到 C 的 BNF 语法，
我们可以看到数组下标的优先级
比括号*稍微*低一点：

```
primary_expression
        : IDENTIFIER
        | CONSTANT
        | STRING_LITERAL
        | '(' expression ')'
        ;

postfix_expression
        : primary_expression
        | postfix_expression '[' expression ']'
          ...
```

不过眼下，
我还是打算继续在 `primary()` 里解析数组下标。
而为了完成其中的语义分析（semantic analysis），
代码已经复杂到值得单独拆出一个函数：

```c
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;


  switch (Token.token) {
  case T_IDENT:
    // This could be a variable, array index or a
    // function call. Scan in the next token to find out
    scan(&Token);

    // It's a '(', so a function call
    if (Token.token == T_LPAREN) return (funccall());

    // It's a '[', so an array reference
    if (Token.token == T_LBRACKET) return (array_access());
```

下面就是 `array_access()`：

```c
// Parse the index into an array and
// return an AST tree for it
static struct ASTnode *array_access(void) {
  struct ASTnode *left, *right;
  int id;

  // Check that the identifier has been defined as an array
  // then make a leaf node for it that points at the base
  if ((id = findglob(Text)) == -1 || Gsym[id].stype != S_ARRAY) {
    fatals("Undeclared array", Text);
  }
  left = mkastleaf(A_ADDR, Gsym[id].type, id);

  // Get the '['
  scan(&Token);

  // Parse the following expression
  right = binexpr(0);

  // Get the ']'
  match(T_RBRACKET, "]");

  // Ensure that this is of int type
  if (!inttype(right->type))
    fatal("Array index is not of integer type");

  // Scale the index by the size of the element's type
  right = modify_type(right, left->type, A_ADD);

  // Return an AST tree where the array's base has the offset
  // added to it, and dereference the element. Still an lvalue
  // at this point.
  left = mkastnode(A_ADD, Gsym[id].type, left, NULL, right, 0);
  left = mkastunary(A_DEREF, value_at(left->type), left, 0);
  return (left);
}
```

对于数组 `int x[20];` 和访问 `x[6]` 这件事，
我们需要先把下标 `6`
按 `int` 的大小（4）做缩放，
再把它加到数组基地址上。
然后还必须对这个元素做一次解引用。
这里我们仍然把它标记为 lvalue，
因为我们完全可能是在处理下面这种写法：

```c
  x[6] = 100;
```

如果它最终需要变成 rvalue，
那么 `binexpr()` 会去设置 `A_DEREF` AST 节点上的 `rvalue` 标志。

### 生成出来的 AST 树

回到测试程序 `tests/input20.c`，
其中会生成数组下标 AST 的代码是：

```c
  b[3]= 12; a= b[3];
```

运行 `comp1 -T tests/input20.c`，
我们会得到：

```
    A_INTLIT 12
  A_WIDEN
      A_ADDR b
        A_INTLIT 3    # 3 is scaled by 4
      A_SCALE 4
    A_ADD             # and then added to b's address
  A_DEREF             # and derefenced. Note, stll an lvalue
A_ASSIGN

      A_ADDR b
        A_INTLIT 3    # As above
      A_SCALE 4
    A_ADD
  A_DEREF rval        # but the dereferenced address will be an rvalue
  A_IDENT a
A_ASSIGN
```

### 其他一些小的解析改动

`expr.c` 里还有两处较小的解析器修改，
但我当时花了不少时间才把它们调对。
首先，
我必须更严格地约束传给“运算符优先级查询函数”的输入：

```c
// Check that we have a binary operator and
// return its precedence.
static int op_precedence(int tokentype) {
  int prec;
  if (tokentype >= T_VOID)
    fatald("Token with no precedence in op_precedence:", tokentype);
  ...
}
```

在把解析逻辑调正确之前，
我一度把一个“不在优先级表里”的 token 传了进去，
结果 `op_precedence()` 直接越界读到了表后面的内容。
哎，C 语言就是这么“可爱”，不是吗？

另一处改动是：
既然现在数组下标里也可以写表达式
（例如 `x[ a+2 ]`），
那我们就必须接受 `']'` 也可能成为一个表达式的结束标记。
因此，在 `binexpr()` 的末尾：

```c
    // Update the details of the current token.
    // If we hit a semicolon, ')' or ']', return just the left node
    tokentype = Token.token;
    if (tokentype == T_SEMI || tokentype == T_RPAREN
        || tokentype == T_RBRACKET) {
      left->rvalue = 1;
      return (left);
    }
  }
```

## 对代码生成器的修改

没有。
编译器里该有的组成部分其实之前已经都准备好了：
缩放整数值、取变量地址等等都已经能做。
对于我们的测试代码：

```c
  b[3]= 12; a= b[3];
```

最终生成的 x86-64 汇编代码是：

```
        movq    $12, %r8
        leaq    b(%rip), %r9    # Get b's address
        movq    $3, %r10
        salq    $2, %r10        # Shift 3 by 2, i.e. 3 * 4
        addq    %r9, %r10       # Add to b's address
        movq    %r8, (%r10)     # Save 12 into b[3]

        leaq    b(%rip), %r8    # Get b's address
        movq    $3, %r9
        salq    $2, %r9         # Shift 3 by 2, i.e. 3 * 4
        addq    %r8, %r9        # Add to b's address
        movq    (%r9), %r9      # Load b[3] into %r9
        movl    %r9d, a(%rip)   # and store in a
```

## 总结与下一步

为了支持基础数组声明和数组表达式，
从“语法处理”这个角度看，
解析器上的改动其实并不算难。
真正让我觉得麻烦的，
是如何把 AST 节点组织正确：
既要缩放下标、加到基地址上，
还要正确设置成 lvalue 或 rvalue。
而一旦这部分搞对了，
现有代码生成器就能自然产出正确的汇编。

在编译器编写之旅的下一部分中，
我们会给语言加入字符字面量和字符串字面量，
并找到把它们打印出来的方法。 [下一步](../20_Char_Str_Literals/Readme.md)
