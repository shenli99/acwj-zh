# 第 20 部分：字符与字符串字面量

我早就想用我们的编译器打印出 `"Hello world"` 了。
既然现在已经有了指针和数组，
那这部分正好可以把字符字面量（character literal）
和字符串字面量（string literal）加进来。

它们当然都属于字面量（literal value），
也就是“源码里直接写出来的值”。
字符字面量是由单引号包起来的单个字符；
字符串字面量则是由双引号包起来的一串字符。

说真的，
C 语言里的字符和字符串字面量设计得相当疯狂。
我这里只打算实现最直观的那些反斜杠转义字符。
另外，为了省事，
我还会直接借用 SubC 里扫描字符与字符串字面量的代码。

这一部分会比较短，
但最后它会让我们真的打印出 `"Hello world"`。

## 一个新 token

我们的语言只需要新增一个 token：`T_STRLIT`。
它和 `T_IDENT` 很像，
因为和这个 token 关联的文本内容
也是保存在全局 `Text` 里，
而不是放在 token 结构体本身。

## 扫描字符字面量

字符字面量以一个单引号开始，
中间是单个字符的定义，
最后再以一个单引号结束。
解释这个字符本身的代码稍微有点复杂，
所以我们修改 `scan.c` 里的 `scan()`，
让它去调用专门的逻辑：

```c
      case '\'':
      // If it's a quote, scan in the
      // literal character value and
      // the trailing quote
      t->intvalue = scanch();
      t->token = T_INTLIT;
      if (next() != '\'')
        fatal("Expected '\\'' at end of char literal");
      break;
```

我们可以把字符字面量当作“类型为 `char` 的整数字面量”来处理；
前提当然是我们把范围限制在 ASCII 内，
而不去碰 Unicode。
我这里采用的就是这种做法。

### `scanch()` 的代码

`scanch()` 的代码来自 SubC，
我只做了少量简化：

```c
// Return the next character from a character
// or string literal
static int scanch(void) {
  int c;

  // Get the next input character and interpret
  // metacharacters that start with a backslash
  c = next();
  if (c == '\\') {
    switch (c = next()) {
      case 'a':  return '\a';
      case 'b':  return '\b';
      case 'f':  return '\f';
      case 'n':  return '\n';
      case 'r':  return '\r';
      case 't':  return '\t';
      case 'v':  return '\v';
      case '\\': return '\\';
      case '"':  return '"' ;
      case '\'': return '\'';
      default:
        fatalc("unknown escape sequence", c);
    }
  }
  return (c);                   // Just an ordinary old character!
}
```

这段代码能够识别大多数常见的转义字符序列，
但不会去支持八进制字符编码之类更麻烦的情况。

## 扫描字符串字面量

字符串字面量以双引号开始，
后面跟着零个或多个字符，
最后再以双引号结束。
和字符字面量一样，
我们也需要在 `scan()` 中调用单独的函数：

```c
    case '"':
      // Scan in a literal string
      scanstr(Text);
      t->token= T_STRLIT;
      break;
```

我们创建一个新的 `T_STRLIT`，
并把字符串扫描到 `Text` 缓冲区中。
下面是 `scanstr()` 的代码：

```c
// Scan in a string literal from the input file,
// and store it in buf[]. Return the length of
// the string. 
static int scanstr(char *buf) {
  int i, c;

  // Loop while we have enough buffer space
  for (i=0; i<TEXTLEN-1; i++) {
    // Get the next char and append to buf
    // Return when we hit the ending double quote
    if ((c = scanch()) == '"') {
      buf[i] = 0;
      return(i);
    }
    buf[i] = c;
  }
  // Ran out of buf[] space
  fatal("String literal too long");
  return(0);
}
```

我觉得这段代码很直接。
它会给扫描出来的字符串补上 NUL 终止符，
并确保不会写爆 `Text` 缓冲区。
注意这里逐个字符扫描时，
我们复用了前面的 `scanch()`。

## 解析字符串字面量

正如前面提到的，
字符字面量会被当作整数字面量处理，
而这部分我们早就支持了。
那字符串字面量可以出现在什么位置？
回到 Jeff Lee 在 1985 年写的
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)，
我们可以看到：

```
primary_expression
        : IDENTIFIER
        | CONSTANT
        | STRING_LITERAL
        | '(' expression ')'
        ;
```

因此我们知道，
应该去修改 `expr.c` 里的 `primary()`：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;


  switch (Token.token) {
  case T_STRLIT:
    // For a STRLIT token, generate the assembly for it.
    // Then make a leaf AST node for it. id is the string's label.
    id= genglobstr(Text);
    n= mkastleaf(A_STRLIT, P_CHARPTR, id);
    break;
```

现在，
我准备把字符串字面量实现成一个“匿名全局字符串”。
它需要把字符串里的所有字符都实际存到内存里，
同时我们还得有办法引用它。
我不想因为这种字符串去污染符号表，
所以这里的做法是：
给这个字符串分配一个 label，
再把这个 label 的编号存进该字符串字面量对应的 AST 节点。
同时还需要新增一种 AST 节点类型：`A_STRLIT`。
这个 label 本质上就是字符串字符数组的基地址，
因此它的类型应该是 `P_CHARPTR`。

稍后我会再讲负责生成汇编输出的 `genglobstr()`。

### 一个 AST 树示例

目前，
字符串字面量会被当作匿名指针来处理。
下面是这条语句对应的 AST：

```c
  char *s;
  s= "Hello world";

  A_STRLIT rval label L2
  A_IDENT s
A_ASSIGN
```

它们两边的类型完全一致，
因此不需要做缩放或扩宽。

## 生成汇编输出

在通用代码生成器（generic code generator）里，
需要改的地方很少。
我们需要一个函数来为新字符串生成存储空间：
先为它分配一个 label，
再输出这个字符串的内容（位于 `gen.c`）：

```c
int genglobstr(char *strvalue) {
  int l= genlabel();
  cgglobstr(l, strvalue);
  return(l);
}
```

同时我们还要识别 `A_STRLIT` 这种 AST 节点类型，
并为它生成汇编代码。
在 `genAST()` 里：

```c
    case A_STRLIT:
        return (cgloadglobstr(n->v.id));
```

## 生成 x86-64 汇编输出

终于来到真正新增的汇编输出函数了。
一共有两个：
一个负责生成字符串的存储空间，
另一个负责把这个字符串的基地址加载出来。

```c
// Generate a global string and its start label
void cgglobstr(int l, char *strvalue) {
  char *cptr;
  cglabel(l);
  for (cptr= strvalue; *cptr; cptr++) {
    fprintf(Outfile, "\t.byte\t%d\n", *cptr);
  }
  fprintf(Outfile, "\t.byte\t0\n");
}

// Given the label number of a global string,
// load its address into a new register
int cgloadglobstr(int id) {
  // Get a new register
  int r = alloc_register();
  fprintf(Outfile, "\tleaq\tL%d(\%%rip), %s\n", id, reglist[r]);
  return (r);
}
```

回到刚才的例子：

```c
  char *s;
  s= "Hello world";
```

它生成的汇编输出是：

```
L2:     .byte   72              # Anonymous string
        .byte   101
        .byte   108
        .byte   108
        .byte   111
        .byte   32
        .byte   119
        .byte   111
        .byte   114
        .byte   108
        .byte   100
        .byte   0
        ...
        leaq    L2(%rip), %r8   # Load L2's address
        movq    %r8, s(%rip)    # and store in s
```

## 其他零碎改动

在给这一部分写测试程序时，
我又挖出了旧代码里的另一个 bug。
当把一个整数值按“指针所指向类型的大小”去做缩放时，
如果缩放因子是 1，
我原本忘记写“什么都不做”的分支了。
现在 `types.c` 里 `modify_type()` 的代码变成了：

```c
    // Left is int type, right is pointer type and the size
    // of the original type is >1: scale the left
    if (inttype(ltype) && ptrtype(rtype)) {
      rsize = genprimsize(value_at(rtype));
      if (rsize > 1)
        return (mkastunary(A_SCALE, rtype, tree, rsize));
      else
        return (tree);          // Size 1, no need to scale
    }
```

之前我漏掉了 `return (tree)`，
结果在尝试缩放 `char *` 指针时，
函数会直接返回一个 `NULL` 树。

## 总结与下一步

我非常高兴，
因为我们现在终于能输出文本了：

```
$ make test
./comp1 tests/input21.c
cc -o out out.s lib/printint.c
./out
10
Hello world
```

这次的大部分工作，
都在于扩展词法扫描器，
让它能处理字符与字符串字面量的定界符，
以及其中字符的转义规则。
不过代码生成器这边也确实做了一些改动。

在编译器编写之旅的下一部分中，
我们会给语言再补上一些新的二元运算符。 [下一步](../21_More_Operators/Readme.md)
