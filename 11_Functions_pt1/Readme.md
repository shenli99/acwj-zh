# 第 11 部分：函数，第 1 部分

我想开始在这门语言中实现函数，但我知道这会牵扯出大量步骤。
沿途我们必须处理的问题包括：

 + 数据类型：`char`、`int`、`long` 等
 + 每个函数的返回类型
 + 每个函数的参数个数
 + 函数局部变量与全局变量之间的区别

这些内容显然不可能在这一部分里全部完成。
所以我在这里的目标是：先走到“能够声明不同函数”的阶段。
最终生成的可执行程序里，仍然只有 `main()` 会真正运行，
但我们已经具备为多个函数生成代码的能力。

希望再过不久，编译器所识别的这门语言就会成为一个足够像 C 的子集，
以至于“真正的” C 编译器也能看懂我们的输入。
不过现在还差一点。

## 一个非常简化的函数语法

这显然只是个占位版本，
目的是先让我们能解析出“长得像函数”的东西。
一旦这个基础打好，
我们再继续往上叠加那些重要特性：类型、返回类型、参数等等。

所以，眼下我先加入下面这套 BNF 函数语法：

```
 function_declaration: 'void' identifier '(' ')' compound_statement   ;
```

所有函数都声明为 `void`，
而且不带参数。
我们也暂时不引入函数调用能力，
因此最终仍然只有 `main()` 会执行。

我们需要一个新的关键字 `void`，
以及一个新的 token `T_VOID`，这两样都很容易加入。

## 解析这个简化函数语法

这个新语法简单到我们可以写一个很短的小函数来解析它
（位于 `decl.c`）：

```c
// Parse the declaration of a simplistic function
struct ASTnode *function_declaration(void) {
  struct ASTnode *tree;
  int nameslot;

  // Find the 'void', the identifier, and the '(' ')'.
  // For now, do nothing with them
  match(T_VOID, "void");
  ident();
  nameslot= addglob(Text);
  lparen();
  rparen();

  // Get the AST tree for the compound statement
  tree= compound_statement();

  // Return an A_FUNCTION node which has the function's nameslot
  // and the compound statement sub-tree
  return(mkastunary(A_FUNCTION, tree, nameslot));
}
```

这段代码负责语法检查和 AST 构建，
但在语义错误检查上几乎还没做什么。
例如，如果一个函数被重复声明了怎么办？
目前我们还完全察觉不到。

## 对 `main()` 的修改

有了上面的函数之后，
我们现在可以改写 `main()` 中的一部分代码，
让它能够连续解析多个函数：

```c
  scan(&Token);                 // Get the first token from the input
  genpreamble();                // Output the preamble
  while (1) {                   // Parse a function and
    tree = function_declaration();
    genAST(tree, NOREG, 0);     // generate the assembly code for it
    if (Token.token == T_EOF)   // Stop when we have reached EOF
      break;
  }
```

注意，我把 `genpostamble()` 的调用去掉了。
因为它之前输出的实际上只是 `main()` 函数汇编代码的收尾部分。
现在我们需要的是：有一套代码生成函数，
专门用来生成“函数开头”和“函数结尾”。

## 为函数添加通用代码生成

既然现在有了 `A_FUNCTION` AST 节点，
那我们当然得在通用代码生成器 `gen.c` 中加入对应逻辑。
回头看上面的构造方式，
它是一个*一元* AST 节点，只带一个孩子：

```c
  // Return an A_FUNCTION node which has the function's nameslot
  // and the compound statement sub-tree
  return(mkastunary(A_FUNCTION, tree, nameslot));
```

这个孩子就是保存函数体复合语句的那棵子树。
而我们必须在生成复合语句代码*之前*，
先把函数的起始汇编代码生出来。
因此 `genAST()` 中加入了下面这段逻辑：

```c
    case A_FUNCTION:
      // Generate the function's preamble before the code
      cgfuncpreamble(Gsym[n->v.id].name);
      genAST(n->left, NOREG, n->op);
      cgfuncpostamble();
      return (NOREG);
```

## x86-64 代码生成

到这里，我们就必须生成每个函数建立栈指针和帧指针的代码，
并在函数末尾撤销这些设置，然后返回给调用者。

其实这套代码我们早就在 `cgpreamble()` 和 `cgpostamble()` 里有了，
只不过 `cgpreamble()` 还顺带包含了 `printint()` 函数的汇编实现。
因此现在要做的，只是把这些汇编片段拆到 `cg.c` 里的新函数中：

```c
// Print out the assembly preamble
void cgpreamble() {
  freeall_registers();
  // Only prints out the code for printint()
}

// Print out a function preamble
void cgfuncpreamble(char *name) {
  fprintf(Outfile,
          "\t.text\n"
          "\t.globl\t%s\n"
          "\t.type\t%s, @function\n"
          "%s:\n" "\tpushq\t%%rbp\n"
          "\tmovq\t%%rsp, %%rbp\n", name, name, name);
}

// Print out a function postamble
void cgfuncpostamble() {
  fputs("\tmovl $0, %eax\n" "\tpopq     %rbp\n" "\tret\n", Outfile);
}
```

## 测试函数生成功能

现在有了一个新的测试程序 `tests/input08`，
它已经开始看起来像一份 C 程序了
（除了 `print` 语句这一点）：

```c
void main()
{
  int i;
  for (i= 1; i <= 10; i= i + 1) {
    print i;
  }
}
```

要测试它，可以执行 `make test8`，也就是：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
    stmt.c sym.c tree.c
./comp1 tests/input08
cc -o out out.s
./out
1
2
3
4
5
6
7
8
9
10
```

我这里就不再看汇编输出了，
因为它和上一部分 `for` 循环测试里生成的代码完全一样。

不过，我已经把之前所有测试输入文件都改成了包含 `void main()`，
因为现在这门语言要求：
在复合语句代码之前必须先有一个函数声明。

测试程序 `tests/input09` 里声明了两个函数。
编译器现在已经能为这两个函数都生成可用的汇编代码，
只是目前我们还不能真正运行第二个函数的代码。

## 总结与下一步

我们已经为语言中的函数支持开了一个不错的头。
当然，目前还只是非常简化的函数声明而已。

在编译器编写之旅的下一部分中，
我们会开始为编译器加入类型系统。 [下一步](../12_Types_pt1/Readme.md)
