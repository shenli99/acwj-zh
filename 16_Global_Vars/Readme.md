# 第 16 部分：正确声明全局变量

我之前确实答应过要研究“给指针加偏移量”这个问题，
但在动手之前我还得再想一想。
所以这一次我先决定把全局变量声明从函数声明里移出去。
实际上，我也暂时保留了“在函数内部解析变量声明”的逻辑，
因为之后我们会把它们改造成局部变量声明。

我还想扩展语法，
让我们能一次声明多个同类型变量，例如：

```c
  int x, y, z;
```

## 新的 BNF 语法

下面是函数和变量这两类全局声明的新 BNF 语法：

```
 global_declarations : global_declarations 
      | global_declaration global_declarations
      ;

 global_declaration: function_declaration | var_declaration ;

 function_declaration: type identifier '(' ')' compound_statement   ;

 var_declaration: type identifier_list ';'  ;

 type: type_keyword opt_pointer  ;
 
 type_keyword: 'void' | 'char' | 'int' | 'long'  ;
 
 opt_pointer: <empty> | '*' opt_pointer  ;
 
 identifier_list: identifier | identifier ',' identifier_list ;
```

`function_declaration` 和 `global_declaration`
现在都以一个 `type` 开始。
而 `type` 本身由一个 `type_keyword`
再加上零个或多个 `'*'` 组成的 `opt_pointer` 构成。
在这之后，
无论是 `function_declaration` 还是 `global_declaration`，
都必须先跟着一个标识符。

不过，在 `type` 之后，
`var_declaration` 跟着的是一个 `identifier_list`，
也就是一个或多个由逗号分隔的标识符。
此外，`var_declaration` 必须以 `';'` 结束，
而 `function_declaration` 则以 `compound_statement` 结束，
因此它不带分号。

## 新 token

现在我们在 `scan.c` 中新增了 `','` 对应的 token：`T_COMMA`。

## 对 `decl.c` 的修改

接下来，我们把上面的 BNF 语法转成递归下降解析函数。
不过因为很多地方都可以循环处理，
所以我们可以把部分递归改成内部循环。

### `global_declarations()`

由于全局声明是“一条或多条”，
所以完全可以循环去解析每一条。
等 token 耗尽时，再退出循环。

```c
// Parse one or more global declarations, either
// variables or functions
void global_declarations(void) {
  struct ASTnode *tree;
  int type;

  while (1) {

    // We have to read past the type and identifier
    // to see either a '(' for a function declaration
    // or a ',' or ';' for a variable declaration.
    // Text is filled in by the ident() call.
    type = parse_type();
    ident();
    if (Token.token == T_LPAREN) {

      // Parse the function declaration and
      // generate the assembly code for it
      tree = function_declaration(type);
      genAST(tree, NOREG, 0);
    } else {

      // Parse the global variable declaration
      var_declaration(type);
    }

    // Stop when we have reached EOF
    if (Token.token == T_EOF)
      break;
  }
}
```

目前已知我们只有“全局变量”和“函数”这两类全局声明，
因此可以先把类型和第一个标识符读出来。
再看下一个 token：
如果它是 `'('`，
就说明这是 `function_declaration()`；
否则就可以假定它是 `var_declaration()`。
这里我们把 `type` 同时传给这两个函数。

既然现在 `function_declaration()` 返回 AST `tree`，
我们也就可以在这里立即调用 `genAST()` 生成代码。
这段逻辑原先是在 `main()` 中，
现在已经移到这里了。
于是 `main()` 只需要调用 `global_declarations()`：

```c
  scan(&Token);                 // Get the first token from the input
  genpreamble();                // Output the preamble
  global_declarations();        // Parse the global declarations
  genpostamble();               // Output the postamble
```

### `var_declaration()`

函数声明的解析整体上和以前差不多，
只是扫描类型和标识符的工作现在被提前放到外面完成了，
函数本身只需要接收 `type` 参数。

变量声明这边也同样去掉了类型与首个标识符的扫描逻辑。
我们可以直接把标识符加入全局符号表，
并为它生成对应的汇编存储代码。
但现在还要再加一个循环：
如果后面跟着的是 `','`，
就继续读下一个同类型标识符；
如果后面跟着的是 `';'`，
说明这一组变量声明结束。

```c
// Parse the declaration of a list of variables.
// The identifier has been scanned & we have the type
void var_declaration(int type) {
  int id;

  while (1) {
    // Text now has the identifier's name.
    // Add it as a known identifier
    // and generate its space in assembly
    id = addglob(Text, type, S_VARIABLE, 0);
    genglobsym(id);

    // If the next token is a semicolon,
    // skip it and return.
    if (Token.token == T_SEMI) {
      scan(&Token);
      return;
    }
    // If the next token is a comma, skip it,
    // get the identifier and loop back
    if (Token.token == T_COMMA) {
      scan(&Token);
      ident();
      continue;
    }
    fatal("Missing , or ; after identifier");
  }
}
```

## 还不算真正的局部变量

`var_declaration()` 现在已经能解析一整串变量声明，
但它要求“类型”和“第一个标识符”都已经在外面预先扫描好了。

因此，我暂时保留了 `stmt.c` 中
`single_statement()` 对 `var_declaration()` 的调用。
以后我们会把这部分改成真正的局部变量声明。
不过眼下，下面这个示例程序里的所有变量其实仍然都是全局变量：

```c
int   d, f;
int  *e;

int main() {
  int a, b, c;
  b= 3; c= 5; a= b + c * 10;
  printint(a);

  d= 12; printint(d);
  e= &d; f= *e; printint(f);
  return(0);
}
```

## 测试这些改动

上面的代码就是我们的 `tests/input16.c`。
照例可以直接测试：

```
$ make test16
cc -o comp1 -g -Wall cg.c decl.c expr.c gen.c main.c misc.c scan.c
      stmt.c sym.c tree.c types.c
./comp1 tests/input16.c
cc -o out out.s lib/printint.c
./out
53
12
12
```


## 总结与下一步

在编译器编写之旅的下一部分中，
我保证会真正去处理“给指针加偏移量”这个问题。 [下一步](../17_Scaling_Offsets/Readme.md)
