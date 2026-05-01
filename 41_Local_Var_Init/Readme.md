# 第 41 部分：局部变量初始化

经历了上一部分那一大串改动之后，
这一部分里要做“局部变量初始化”
反而变得很简单。

我们希望在函数内部能够写出这样的代码：

```c
  int x= 2, y= x+3, z= 5 * x - y;
  char *foo= "Hello world";
```

既然现在已经处在函数内部，
那我们就可以为右侧表达式构建 AST，
为变量本身构建一个 `A_IDENT` 节点，
再用一个 `A_ASSIGN` 父节点把两边接起来。
同时，
由于一条声明里可能包含多个带赋值的变量，
所以我们还可能需要一棵 `A_GLUE` 树，
把所有这些赋值子树串起来。

唯一的小弯在于：
负责解析局部声明的代码，
和负责解析普通语句的代码，
在调用层级上其实隔得有点远。
准确地说：

 + `stmt.c` 里的 `single_statement()` 先看到一个类型标识符，然后调用
 + `decl.c` 里的 `declaration_list()` 去解析多个声明，而它又调用
 + `symbol_declaration()` 去解析单个声明，而它再调用
 + `scalar_declaration()` 去解析标量变量声明与赋值

主要问题在于，
这些函数本身各自已经都有自己的返回值了，
所以我们没法直接在 `scalar_declaration()`
里构建 AST，
再一路把它通过返回值传回 `single_statement()`。

另外，
`declaration_list()` 本身还负责一次解析多个声明，
所以它还必须承担起“构建那棵把多个赋值串起来的 `A_GLUE` 树”的工作。

解决办法是：
从 `single_statement()` 往下传一个“双重指针（pointer pointer）”
给 `declaration_list()`，
这样就能把最终那棵 `A_GLUE` 树的指针回传回来。
同样地，
我们还会从 `declaration_list()` 再往下传一个“双重指针”
给 `scalar_declaration()`，
让它把自己构建出来的赋值树指针回传上来。

## 对 `scalar_declaration()` 的修改

如果当前处在局部作用域，
并且在标量变量声明里遇到了 `'='`，
那现在的做法是这样：

```c
  struct ASTnode *varnode, *exprnode;
  struct ASTnode **tree;                 // is the ptr ptr argument that we get passed

  // The variable is being initialised
  if (Token.token == T_ASSIGN) {
    ...
    if (class == C_LOCAL) {
      // Make an A_IDENT AST node with the variable
      varnode = mkastleaf(A_IDENT, sym->type, sym, 0);

      // Get the expression for the assignment, make into a rvalue
      exprnode = binexpr(0);
      exprnode->rvalue = 1;

      // Ensure the expression's type matches the variable
      exprnode = modify_type(exprnode, varnode->type, 0);
      if (exprnode == NULL)
        fatal("Incompatible expression in assignment");

      // Make an assignment AST tree
      *tree = mkastnode(A_ASSIGN, exprnode->type, exprnode,
                                        NULL, varnode, NULL, 0);
    }
  }
```

就这么多。
这里我们只是模拟了
`expr.c` 中通常为赋值表达式所做的 AST 构建过程。
完成之后，
把这棵赋值树通过指针传回去。
然后它会一路回冒到 `declaration_list()`。
而 `declaration_list()` 现在会这样做：

```c
  struct ASTnode **gluetree;            // is the ptr ptr argument that we get passed
  struct ASTnode *tree;
  *gluetree= NULL;
  ...
  // Now parse the list of symbols
  while (1) {
    ...
    // Parse this symbol
    sym = symbol_declaration(type, *ctype, class, &tree);
    ...
    // Glue any AST tree from a local declaration
    // to build a sequence of assignments to perform
    if (*gluetree== NULL)
      *gluetree= tree;
    else
      *gluetree = mkastnode(A_GLUE, P_NONE, *gluetree, NULL, tree, NULL, 0);
    ...
  }
```

所以 `gluetree`
最终会指向一棵由多个 `A_GLUE` 节点串起来的 AST，
其中每一项下面都挂着一个 `A_ASSIGN`，
而每个 `A_ASSIGN`
又会带着一个 `A_IDENT` 子节点和一个表达式子节点。

而在更上层的 `stmt.c` 里，
`single_statement()` 现在会这么写：

```c
    ...
    case T_IDENT:
      // We have to see if the identifier matches a typedef.
      // If not, treat it as an expression.
      // Otherwise, fall down to the parse_type() call.
      if (findtypedef(Text) == NULL) {
        stmt= binexpr(0); semi(); return(stmt);
      }
    case T_CHAR:
    case T_INT:
    case T_LONG:
    case T_STRUCT:
    case T_UNION:
    case T_ENUM:
    case T_TYPEDEF:
      // The beginning of a variable declaration list.
      declaration_list(&ctype, C_LOCAL, T_SEMI, T_EOF, &stmt);
      semi();
      return (stmt);            // Any assignments from the declarations
    ...
```

## 测试新代码

上面这些改动既短又直白，
结果它们第一次编译就工作了。
这种事可不常见！

我们的测试程序 `tests/input100.c`
长这样：

```c
#include <stdio.h>
int main() {
  int x= 3, y=14;
  int z= 2 * x + y;
  char *str= "Hello world";
  printf("%s %d %d\n", str, x+y, z);
  return(0);
}
```

它会生成如下正确输出：
`Hello world 17 20`。

## 总结与下一步

这段旅程里，
偶尔能碰上一个实现起来相对简单的章节，
感觉还真不错。
我现在已经开始和自己打赌：

 + 整个系列最后总共会写多少部分
 + 我能不能在年底前把它全部写完

按我现在的猜测，
大概会有 60 个部分左右，
而在年底前完成的概率大概是 75%。
不过我们前面还剩下一堆细小、
但也许并不轻松的功能要补进编译器里。

在编译器编写之旅的下一部分中，
我会把 cast 的解析加进编译器。 [下一步](../42_Casting/Readme.md)
