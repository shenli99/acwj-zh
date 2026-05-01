# 第 15 部分：指针，第 1 部分

在编译器编写之旅的这一部分中，
我想开始把指针加入语言。
具体来说，我想先支持下面这些能力：

 + 声明指针变量
 + 把一个地址赋给指针
 + 解引用一个指针，取出它所指向的值

考虑到这仍然是一个进行中的实现，
我很确定自己现在只能先做出一个“眼下够用的简化版本”，
但以后还必须继续修改和扩展，
让它变得更通用。

## 新关键字与 token

这次没有新增关键字，
只新增了两个 token：

 + `'&'`，即 `T_AMPER`
 + `'&&'`，即 `T_LOGAND`

虽然我们现在还用不到 `T_LOGAND`，
不过我索性先把这段代码加进 `scan()`：

```c
    case '&':
      if ((c = next()) == '&') {
        t->token = T_LOGAND;
      } else {
        putback(c);
        t->token = T_AMPER;
      }
      break;
```

## 类型相关的新代码

我给语言加入了一些新的基础类型
（定义于 `defs.h`）：

```c
// Primitive types
enum {
  P_NONE, P_VOID, P_CHAR, P_INT, P_LONG,
  P_VOIDPTR, P_CHARPTR, P_INTPTR, P_LONGPTR
};
```

我们将引入两个新的单目**前缀**运算符：

 + `'&'`：获取一个标识符的地址
 + `'*'`：解引用一个指针，取得它指向的值

这两个运算符“作用于什么类型”，
以及“会产生什么类型的表达式”，
这两件事并不相同。
因此在 `types.c` 中，
我们需要两个函数来做这种类型转换：

```c
// Given a primitive type, return
// the type which is a pointer to it
int pointer_to(int type) {
  int newtype;
  switch (type) {
    case P_VOID: newtype = P_VOIDPTR; break;
    case P_CHAR: newtype = P_CHARPTR; break;
    case P_INT:  newtype = P_INTPTR;  break;
    case P_LONG: newtype = P_LONGPTR; break;
    default:
      fatald("Unrecognised in pointer_to: type", type);
  }
  return (newtype);
}

// Given a primitive pointer type, return
// the type which it points to
int value_at(int type) {
  int newtype;
  switch (type) {
    case P_VOIDPTR: newtype = P_VOID; break;
    case P_CHARPTR: newtype = P_CHAR; break;
    case P_INTPTR:  newtype = P_INT;  break;
    case P_LONGPTR: newtype = P_LONG; break;
    default:
      fatald("Unrecognised in value_at: type", type);
  }
  return (newtype);
}
```

那么，这两个函数会在哪些地方用到呢？

## 声明指针变量

我们希望不仅能声明标量变量，
也能声明指针变量，例如：

```c
  char  a; char *b;
  int   d; int  *e;
```

我们已经在 `decl.c` 中有一个 `parse_type()`，
能把类型关键字转换成相应类型。
现在把它扩展一下：
如果后面跟着的是 `'*'`，
就进一步把它变成指针类型：

```c
// Parse the current token and return
// a primitive type enum value. Also
// scan in the next token
int parse_type(void) {
  int type;
  switch (Token.token) {
    case T_VOID: type = P_VOID; break;
    case T_CHAR: type = P_CHAR; break;
    case T_INT:  type = P_INT;  break;
    case T_LONG: type = P_LONG; break;
    default:
      fatald("Illegal type, token", Token.token);
  }

  // Scan in one or more further '*' tokens 
  // and determine the correct pointer type
  while (1) {
    scan(&Token);
    if (Token.token != T_STAR) break;
    type = pointer_to(type);
  }

  // We leave with the next token already scanned
  return (type);
}
```

这段代码甚至允许程序员尝试写出：

```c
   char *****fred;
```

目前它会失败，
因为 `pointer_to()` 还不知道怎样把 `P_CHARPTR`
变成 `P_CHARPTRPTR`。
但 `parse_type()` 的整体结构已经为这种未来扩展做好准备了。

于是 `var_declaration()` 现在就能够很愉快地解析指针变量声明：

```c
// Parse the declaration of a variable
void var_declaration(void) {
  int id, type;

  // Get the type of the variable
  // which also scans in the identifier
  type = parse_type();
  ident();
  ...
}
```

### 前缀运算符 `*` 与 `&`

声明说完之后，
现在来看看表达式解析：
也就是在表达式前面出现 `'*'` 和 `'&'` 这两个前缀运算符时该怎么办。
对应的 BNF 语法如下：

```
 prefix_expression: primary
     | '*' prefix_expression
     | '&' prefix_expression
     ;
```

从语法上说，
这理论上允许写出：

```
   x= ***y;
   a= &&&b;
```

为了阻止这些明显不合理的用法，
我们加上一些语义检查。代码如下：

```c
// Parse a prefix expression and return 
// a sub-tree representing it.
struct ASTnode *prefix(void) {
  struct ASTnode *tree;
  switch (Token.token) {
    case T_AMPER:
      // Get the next token and parse it
      // recursively as a prefix expression
      scan(&Token);
      tree = prefix();

      // Ensure that it's an identifier
      if (tree->op != A_IDENT)
        fatal("& operator must be followed by an identifier");

      // Now change the operator to A_ADDR and the type to
      // a pointer to the original type
      tree->op = A_ADDR; tree->type = pointer_to(tree->type);
      break;
    case T_STAR:
      // Get the next token and parse it
      // recursively as a prefix expression
      scan(&Token); tree = prefix();

      // For now, ensure it's either another deref or an
      // identifier
      if (tree->op != A_IDENT && tree->op != A_DEREF)
        fatal("* operator must be followed by an identifier or *");

      // Prepend an A_DEREF operation to the tree
      tree = mkastunary(A_DEREF, value_at(tree->type), tree, 0);
      break;
    default:
      tree = primary();
  }
  return (tree);
}
```

这里我们仍然是在做递归下降解析，
但也加上了错误检查，
用来阻止明显的输入错误。
目前 `value_at()` 的限制会阻止出现多个连续 `'*'`，
不过等以后我们修改 `value_at()` 时，
就不需要再回来改 `prefix()` 了。

注意，`prefix()` 在没有看到 `'*'` 或 `'&'` 时，
最终还是会调用 `primary()`。
这也就允许我们修改 `binexpr()` 中已有的代码：

```c
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  int lefttype, righttype;
  int tokentype;

  // Get the tree on the left.
  // Fetch the next token at the same time.
  // Used to be a call to primary().
  left = prefix();
  ...
}
```

## 新的 AST 节点类型

前面的 `prefix()` 中，
我引入了两个新的 AST 节点类型
（定义在 `defs.h` 中）：

 + `A_DEREF`：对孩子节点中的指针做解引用
 + `A_ADDR`：取得这个节点中标识符的地址

注意，`A_ADDR` 不是一个父节点。
对于表达式 `&fred`，
`prefix()` 里的代码会直接把原本 “fred” 节点中的 `A_IDENT`
改成 `A_ADDR`。

## 生成新的汇编代码

在通用代码生成器 `gen.c` 中，
对 `genAST()` 的改动只有很少几行：

```c
    case A_ADDR:
      return (cgaddress(n->v.id));
    case A_DEREF:
      return (cgderef(leftreg, n->left->type));
```

`A_ADDR` 节点负责生成代码，
把标识符 `n->v.id` 的地址装进一个寄存器。
而 `A_DEREF` 节点则取出保存在 `leftreg` 中的指针地址，
再结合它对应的类型，
返回该地址上存储的值。

### x86-64 实现

我通过研究其他编译器生成的汇编，
整理出了下面这套输出。
它未必完全正确！

```c
// Generate code to load the address of a global
// identifier into a variable. Return a new register
int cgaddress(int id) {
  int r = alloc_register();

  fprintf(Outfile, "\tleaq\t%s(%%rip), %s\n", Gsym[id].name, reglist[r]);
  return (r);
}

// Dereference a pointer to get the value it
// pointing at into the same register
int cgderef(int r, int type) {
  switch (type) {
    case P_CHARPTR:
      fprintf(Outfile, "\tmovzbq\t(%s), %s\n", reglist[r], reglist[r]);
      break;
    case P_INTPTR:
    case P_LONGPTR:
      fprintf(Outfile, "\tmovq\t(%s), %s\n", reglist[r], reglist[r]);
      break;
  }
  return (r);
}
```

`leaq` 指令负责把某个命名标识符的地址加载进寄存器。
而在第二个函数里，
像 `(%r8)` 这样的语法，
表示“加载 `%r8` 指向位置上的值”。

## 测试新的功能

下面是新的测试文件 `tests/input15.c`，
以及编译运行后的结果：

```c
int main() {
  char  a; char *b; char  c;
  int   d; int  *e; int   f;

  a= 18; printint(a);
  b= &a; c= *b; printint(c);

  d= 12; printint(d);
  e= &d; f= *e; printint(f);
  return(0);
}

```

```
$ make test15
cc -o comp1 -g -Wall cg.c decl.c expr.c gen.c main.c misc.c
   scan.c stmt.c sym.c tree.c types.c
./comp1 tests/input15.c
cc -o out out.s lib/printint.c
./out
18
18
12
12
```

我决定把测试文件的后缀统一改成 `.c`，
因为它们现在确实已经是 C 程序了。
我也顺手修改了 `tests/mktests` 脚本，
让它通过“真正的”编译器来编译这些测试文件，
从而生成*正确*结果。

## 总结与下一步

现在指针支持已经有了一个开头，
但它还远远不算完整正确。
例如，如果我写出下面这段代码：

```c
int main() {
  int x; int y;
  int *iptr;
  x= 10; y= 20;
  iptr= &x + 1;
  printint( *iptr);
}
```

它本来应该打印 20，
因为 `&x + 1` 应该表示“比 `x` 往后一个 `int` 的地址”，
也就是变量 `y`。
它相对于 `x` 应该偏移 8 个字节。

但现在我们的编译器只是单纯地把 `x` 的地址加 1，
这是错误的。
我还得继续研究，看看怎么修正这个问题。

在编译器编写之旅的下一部分中，
我们就来尝试修复它。 [下一步](../16_Global_Vars/Readme.md)
