# 第 53 部分：收尾清扫，第 2 部分

在编译器编写之旅的这一部分里，
我修了几件挺烦人的小事，
而它们恰好又都已经出现在编译器自己的源码里了。

## 连续字符串字面量

C 允许把字符串字面量拆成多行，
或者拆成多个紧挨着的字符串，
例如：

```c
  char *c= "hello " "there, "
           "how " "are " "you?";
```

当然，
我们完全可以在词法扫描器里解决这个问题。
但我确实花了不少时间尝试这么做，
结果并不理想。
问题在于：
扫描器现在已经因为 C 预处理器支持而变得比较复杂，
我一直没找到一种足够干净的方式，
来让它正确处理连续字符串字面量。

所以我的解决方案是：
把这件事放到解析器里做，
同时让代码生成器配合一点。
现在在 `expr.c` 的 `primary()` 中，
处理字符串字面量的代码变成了这样：

```c
  case T_STRLIT:
    // For a STRLIT token, generate the assembly for it.
    id = genglobstr(Text, 0);   // 0 means generate a label

    // For successive STRLIT tokens, append their contents
    // to this one
    while (1) {
      scan(&Peektoken);
      if (Peektoken.token != T_STRLIT) break;
      genglobstr(Text, 1);      // 1 means don't generate a label
      scan(&Token);             // Skip it
    }

    // Now make a leaf AST node for it. id is the string's label.
    genglobstrend();
    n = mkastleaf(A_STRLIT, pointer_to(P_CHAR), NULL, NULL, id);
    break;
```

`genglobstr()` 现在多接收了第二个参数，
用来告诉它：
这是字符串的第一段，
还是后续拼接进来的连续部分。
而 `genglobstrend()`
现在则专门负责在最终字符串末尾补上 NUL 终止符。

## 空语句

C 同时允许“空语句”和“空复合语句”，
例如：

```c
  while ((c=getc()) != 'x') ;           // ';' is an empty statement

  int fred() { }                        // Function with empty body
```

而这两种写法我都已经在编译器自己的源码里用到了，
所以我们也得支持它们。
现在 `stmt.c` 里的代码会这样做：

```c
static struct ASTnode *single_statement(void) {
  struct ASTnode *stmt;
  struct symtable *ctype;

  switch (Token.token) {
    case T_SEMI:
      // An empty statement
      semi();
      break;
    ...
  }
  ...
}

struct ASTnode *compound_statement(int inswitch) {
  struct ASTnode *left = NULL;
  struct ASTnode *tree;

  while (1) {
    // Leave if we've hit the end token. We do this first to allow
    // an empty compound statement
    if (Token.token == T_RBRACE)
      return (left);
    ...
  }
  ...
}
```

这样一来，
这两种缺失情况就都修好了。

## 重复声明的符号

C 允许一个全局变量先声明为 `extern`，
后面再真正定义成普通全局变量；
反过来也允许先定义全局变量，
后面再写一个 `extern` 声明。
当然，
前提是两次声明的类型必须一致。

同时我们还得保证：
这个符号最后在符号表里只保留一个版本。
也就是说，
我们不希望同时看到一个 `C_GLOBAL`
和一个 `C_EXTERN` 条目并存。

所以我在 `stmt.c` 里新增了一个函数：
`is_new_symbol()`。
调用时机是在：
我们已经解析出了变量名，
并且也已经尝试去符号表里查找过它之后。
因此传进来的 `sym`
可能是 `NULL`
（说明之前不存在），
也可能不是 `NULL`
（说明这是个已有符号）。

而一旦符号已经存在，
判断它是不是“安全的重新声明”
其实还挺麻烦。

```c
// Given a pointer to a symbol that may already exist
// return true if this symbol doesn't exist. We use
// this function to convert externs into globals
int is_new_symbol(struct symtable *sym, int class, 
                  int type, struct symtable *ctype) {

  // There is no existing symbol, thus is new
  if (sym==NULL) return(1);

  // global versus extern: if they match that it's not new
  // and we can convert the class to global
  if ((sym->class== C_GLOBAL && class== C_EXTERN)
      || (sym->class== C_EXTERN && class== C_GLOBAL)) {

      // If the types don't match, there's a problem
      if (type != sym->type)
        fatals("Type mismatch between global/extern", sym->name);

      // Struct/unions, also compare the ctype
      if (type >= P_STRUCT && ctype != sym->ctype)
        fatals("Type mismatch between global/extern", sym->name);

      // If we get to here, the types match, so mark the symbol
      // as global
      sym->class= C_GLOBAL;
      // Return that symbol is not new
      return(0);
  }

  // It must be a duplicate symbol if we get here
  fatals("Duplicate global variable declaration", sym->name);
  return(-1);   // Keep -Wall happy
}
```

这段代码本身不算难懂，
但也谈不上优雅。
还要注意一点：
任何被重新声明的 `extern` 符号，
最终都会被转换成 `global` 符号。
这样我们就不必把旧符号从表里删掉，
再新建一个全局符号重新插进去。

## 逻辑运算中的操作数类型

接下来我撞上的另一个 bug
大概像这样：

```c
  int *x;
  int y;

  if (x && y > 12) ...
```

编译器在 `binexpr()`
里处理 `&&` 运算。
为此，
它会去检查二元运算符两边的类型是否兼容。
如果这里的运算符是 `'+'`，
那这两个类型显然不兼容；
但对于逻辑比较来说，
我们完全可以把它们
*AND* 在一起。

所以我在 `types.c`
里的 `modify_type()` 顶部又补了一些逻辑。
如果当前处理的是 `&&` 或 `||`，
那两边只要是整数类型或者指针类型就可以。

```c
struct ASTnode *modify_type(struct ASTnode *tree, int rtype,
                            struct symtable *rctype, int op) {
  int ltype;
  int lsize, rsize;

  ltype = tree->type;

  // For A_LOGOR and A_LOGAND, both types have to be int or pointer types
  if (op==A_LOGOR || op==A_LOGAND) {
    if (!inttype(ltype) && !ptrtype(ltype))
      return(NULL);
    if (!inttype(ltype) && !ptrtype(rtype))
      return(NULL);
    return (tree);
  }
  ...
}
```

不过我同时也意识到，
自己对 `&&` 和 `||`
的实现其实还是不完全对。
这个问题现在先记着，
很快就得回来修。

## 没有返回值的 `return`

C 里还有一个此前缺掉的小特性：
在 `void` 函数里，
允许直接 `return;`，
也就是不返回任何值就离开。

但我们当前的解析器，
在看到 `return` 关键字之后，
总是期待后面还跟着括号和一个表达式。

所以现在在 `stmt.c` 的 `return_statement()` 里，
代码变成了这样：

```c
// Parse a return statement and return its AST
static struct ASTnode *return_statement(void) {
  struct ASTnode *tree= NULL;

  // Ensure we have 'return'
  match(T_RETURN, "return");

  // See if we have a return value
  if (Token.token == T_LPAREN) {
    // Code to parse the parentheses and the expression
    ...
  } else {
    if (Functionid->type != P_VOID)
      fatal("Must return a value from a non-void function");
  }


    // Add on the A_RETURN node
  tree = mkastunary(A_RETURN, P_NONE, NULL, tree, NULL, 0);

  // Get the ';'
  semi();
  return (tree);
}
```

如果 `return` 后面没有左括号，
那我们就保持表达式那棵 `tree`
为 `NULL`。
同时还会检查：
当前函数必须确实是一个 `void` 返回函数，
否则就报 fatal 错误。

而既然现在可能解析出
“子节点为 `NULL` 的 `A_RETURN` AST 节点”，
那代码生成器也得跟着适配。
所以 `cg.c` 里的 `cgreturn()`
开头现在会是这样：

```c
// Generate code to return a value from a function
void cgreturn(int reg, struct symtable *sym) {

  // Only return a value if we have a value to return
  if (reg != NOREG) {
    ..
  }

  cgjump(sym->st_endlabel);
}
```

如果对应的 AST 子树不存在，
那自然也就不会有寄存器保存表达式结果。
因此这种情况下，
我们只需要无条件跳到函数结束标签即可。


## 总结与下一步

这一部分里，
我们修掉了编译器中的五个小问题：
它们都是为了让编译器能继续往“编译自己”这件事上推进所必须补齐的。

我确实还发现了 `&&` 和 `||`
这里存在一个实现问题。
但在回头修它之前，
我得先解决另一个更紧急的问题：
我们的 CPU 寄存器数量是有限的，
而在编译较大的源文件时，
它们已经开始不够用了。

在编译器编写之旅的下一部分中，
我必须开始实现“寄存器溢出到栈（register spills）”。
这件事我已经拖了很久，
但现在编译器在尝试编译自己时，
大部分 fatal 错误都已经和寄存器相关了。
所以现在是时候正面处理它了。 [下一步](../54_Reg_Spills/Readme.md)
