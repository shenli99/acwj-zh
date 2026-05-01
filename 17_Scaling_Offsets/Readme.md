# 第 17 部分：更好的类型检查与指针偏移

前几部分里，我引入了指针，
并实现了一些类型兼容性检查代码。
当时我就意识到，
像下面这样的代码：

```c
  int   c;
  int  *e;

  e= &c + 1;
```

其中 `&c` 计算出的指针再加 1 时，
这个 1 实际上必须先转换成 `c` 的大小，
这样才能确保它会跳到 `c` 后面紧邻的下一个 `int` 位置。
换句话说，
我们必须对这个整数做缩放（scale）。

这件事不仅对指针需要，
以后对数组也同样需要。
看看这段代码：

```c
  int list[10];
  int x= list[3];
```

为了得到 `list[3]`，
我们必须先拿到 `list[]` 的基地址，
然后再加上“三倍的 `int` 大小”，
才能定位到索引位置 3 的元素。

当时我在 `types.c` 里写了一个叫 `type_compatible()` 的函数，
用它来判断两个类型是否兼容，
以及是否需要把较小的整数类型“扩宽（widen）”到较大的整数类型。
但这种扩宽操作本身其实是在别处执行的，
最后它分散在编译器里的三个不同位置。

## 用新方案替换 `type_compatible()`

如果 `type_compatible()` 表示需要扩宽，
我们会插入一个 `A_WIDEN` 节点，
让表达式去匹配更大的整数类型。
而现在我们还需要一种 `A_SCALE` 节点，
用来按某个类型的大小去缩放表达式值。
同时，我也想顺手重构掉那些重复的扩宽代码。

因此，我把 `type_compatible()` 丢掉了，重新换了方案。
这件事让我想了很久，
而且将来大概率还得再微调甚至扩展。
先看看设计思路。

原先的 `type_compatible()`：
 + 接收两个类型值作为参数，再加一个可选方向参数
 + 如果两个类型兼容，就返回 true
 + 如果左边或右边需要扩宽，就返回 `A_WIDEN`
 + 但它本身并不会真的把 `A_WIDEN` 节点插进树里
 + 如果类型不兼容，就返回 false
 + 完全不处理指针类型

现在我们来看看“类型比较”实际会出现在哪些用例里：

 + 对两个表达式做二元运算时，它们类型是否兼容？其中一边是否需要扩宽或缩放？
 + 执行 `print` 语句时，表达式是不是整数？是否需要扩宽？
 + 执行赋值语句时，表达式是否需要扩宽？是否匹配左值类型？
 + 执行 `return` 语句时，表达式是否需要扩宽？是否匹配函数返回类型？

而在这四个用例里，
真正“同时有两棵表达式树”的，
其实只有第一个。
因此我决定改成写一个新函数：
它接收“一棵 AST 树”以及“我们希望它变成的目标类型”。
而针对二元运算那个场景，
我们就调用它两次，分别看看每棵树会发生什么。

## 引入 `modify_type()`

`types.c` 里的 `modify_type()` 就是用来替代 `type_compatible()` 的。
它的 API 如下：

```c
// Given an AST tree and a type which we want it to become,
// possibly modify the tree by widening or scaling so that
// it is compatible with this type. Return the original tree
// if no changes occurred, a modified tree, or NULL if the
// tree is not compatible with the given type.
// If this will be part of a binary operation, the AST op is not zero.
struct ASTnode *modify_type(struct ASTnode *tree, int rtype, int op);
```

问题来了：为什么它还需要知道“当前这棵树和另一棵树之间正在做什么二元运算”？
答案是：因为指针只能做加法和减法，
不能参与其他运算。比如：

```c
  int x;
  int *ptr;

  x= *ptr;	   // OK
  x= *(ptr + 2);   // Two ints up from where ptr is pointing
  x= *(ptr * 4);   // Does not make sense
  x= *(ptr / 13);  // Does not make sense either
```

下面就是当前版本的代码。
里面有很多具体判断条件，
而且目前我也还看不出有什么特别优雅的统一方式。
它以后肯定还得扩展。

```c
struct ASTnode *modify_type(struct ASTnode *tree, int rtype, int op) {
  int ltype;
  int lsize, rsize;

  ltype = tree->type;

  // Compare scalar int types
  if (inttype(ltype) && inttype(rtype)) {

    // Both types same, nothing to do
    if (ltype == rtype) return (tree);

    // Get the sizes for each type
    lsize = genprimsize(ltype);
    rsize = genprimsize(rtype);

    // Tree's size is too big
    if (lsize > rsize) return (NULL);

    // Widen to the right
    if (rsize > lsize) return (mkastunary(A_WIDEN, rtype, tree, 0));
  }

  // For pointers on the left
  if (ptrtype(ltype)) {
    // OK is same type on right and not doing a binary op
    if (op == 0 && ltype == rtype) return (tree);
  }

  // We can scale only on A_ADD or A_SUBTRACT operation
  if (op == A_ADD || op == A_SUBTRACT) {

    // Left is int type, right is pointer type and the size
    // of the original type is >1: scale the left
    if (inttype(ltype) && ptrtype(rtype)) {
      rsize = genprimsize(value_at(rtype));
      if (rsize > 1) 
        return (mkastunary(A_SCALE, rtype, tree, rsize));
    }
  }

  // If we get here, the types are not compatible
  return (NULL);
}
```

现在，添加 AST `A_WIDEN` 和 `A_SCALE` 节点的动作，
终于只在这一个地方完成了。
`A_WIDEN` 的含义是：
把孩子节点的类型转换成父节点类型。
而 `A_SCALE` 的含义则是：
把孩子节点的值乘上某个大小，
这个大小存放在 `struct ASTnode` 的新 union 字段中
（定义于 `defs.h`）：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  ...
  union {
    int size;                   // For A_SCALE, the size to scale by
  } v;
};
```

## 使用新的 `modify_type()` API

有了这个新 API 之后，
我们就能把 `stmt.c` 和 `expr.c` 里那些重复插入 `A_WIDEN`
的代码删掉。
而且这个新函数一次只处理“一棵树”，
这在本来就只有一棵树的场景下特别顺手。

现在 `stmt.c` 里一共有三处调用 `modify_type()`。
它们都差不多，
这里拿 `assignment_statement()` 里的那一处举例：

```c
  // Make the AST node for the assignment lvalue
  right = mkastleaf(A_LVIDENT, Gsym[id].type, id);

  ...
  // Parse the following expression
  left = binexpr(0);

  // Ensure the two types are compatible.
  left = modify_type(left, right->type, 0);
  if (left == NULL) fatal("Incompatible expression in assignment");
```

和以前相比，这样整洁多了。

### 以及 `binexpr()` 里的情况……

但在 `expr.c` 的 `binexpr()` 里，
我们现在是用某个二元运算符把两棵 AST 组合起来。
这里就需要分别尝试：
把左树改成右树的类型，
再把右树改成左树的类型。

要注意的是：
某一边成功完成扩宽时，
另一边对应的尝试很可能会失败并返回 `NULL`。
因此我们不能一看到某一边返回 `NULL` 就判定类型不兼容；
必须两边都返回 `NULL`，
才能认定这两个类型根本不匹配。
下面是 `binexpr()` 中新的比较逻辑：

```c
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  struct ASTnode *ltemp, *rtemp;
  int ASTop;
  int tokentype;

  ...
  // Get the tree on the left.
  // Fetch the next token at the same time.
  left = prefix();
  tokentype = Token.token;

  ...
  // Recursively call binexpr() with the
  // precedence of our token to build a sub-tree
  right = binexpr(OpPrec[tokentype]);

  // Ensure the two types are compatible by trying
  // to modify each tree to match the other's type.
  ASTop = arithop(tokentype);
  ltemp = modify_type(left, right->type, ASTop);
  rtemp = modify_type(right, left->type, ASTop);
  if (ltemp == NULL && rtemp == NULL)
    fatal("Incompatible types in binary expression");

  // Update any trees that were widened or scaled
  if (ltemp != NULL) left = ltemp;
  if (rtemp != NULL) right = rtemp;
```

这段代码看起来稍微有点乱，
但不比之前的版本更糟，
而且它现在既能处理 `A_SCALE`，
也能处理 `A_WIDEN`。

## 执行缩放

我们已经把 `A_SCALE` 加入 `defs.h` 中 AST 操作类型列表里。
现在就需要真正实现它。

正如前面所说，
`A_SCALE` 的作用是把孩子节点的值乘上
存放在 `struct ASTnode` union 字段中的那个大小值。
对于我们目前所有的整数类型来说，
这个大小都会是 2 的倍数。
因此我们可以用“左移若干位”来代替乘法。

不过以后我们会引入结构体，
而结构体的大小未必是 2 的幂。
所以现在虽然可以对适合的缩放因子做移位优化，
但仍然必须实现“更一般的乘法缩放”。

`gen.c` 中 `genAST()` 的新代码如下：

```c
    case A_SCALE:
      // Small optimisation: use shift if the
      // scale value is a known power of two
      switch (n->v.size) {
        case 2: return(cgshlconst(leftreg, 1));
        case 4: return(cgshlconst(leftreg, 2));
        case 8: return(cgshlconst(leftreg, 3));
        default:
          // Load a register with the size and
          // multiply the leftreg by this size
          rightreg= cgloadint(n->v.size, P_INT);
          return (cgmul(leftreg, rightreg));
```

## 在 x86-64 上左移

现在我们需要一个 `cgshlconst()`，
用于把寄存器中的值按常量左移。
等以后加入 C 的 `<<` 运算符时，
我会再写一个更通用的左移函数。
眼下我们可以直接使用带整数字面量的 `salq` 指令：

```c
// Shift a register left by a constant
int cgshlconst(int r, int val) {
  fprintf(Outfile, "\tsalq\t$%d, %s\n", val, reglist[r]);
  return(r);
}
```

## 那个原本跑不通的测试程序

我用来测试缩放功能的程序是 `tests/input16.c`：

```c
int   c;
int   d;
int  *e;
int   f;

int main() {
  c= 12; d=18; printint(c);
  e= &c + 1; f= *e; printint(f);
  return(0);
}
```

我本来希望：
当我们生成下面这些汇编指令时，
汇编器会把 `d` 紧挨着放在 `c` 后面：

```
        .comm   c,1,1
        .comm   d,4,4
```

但当我把汇编编译出来再去检查时，
发现它们根本不是相邻的：

```
$ cc -o out out.s lib/printint.c
$ nm -n out | grep 'B '
0000000000201018 B d
0000000000201020 B b
0000000000201028 B f
0000000000201030 B e
0000000000201038 B c
```

`d` 实际上还排在 `c` 前面！
于是我不得不想办法强制保证它们的相邻关系。
最后我参考了 *SubC* 在这里生成的代码，
把我们编译器的输出改成了下面这样：

```
        .data
        .globl  c
c:      .long   0	# Four byte integer
        .globl  d
d:      .long   0
        .globl  e
e:      .quad   0	# Eight byte pointer
        .globl  f
f:      .long   0
```

这样一来，当我们运行 `input16.c` 测试时，
`e= &c + 1; f= *e;`
就会拿到比 `c` 往后一个 `int` 的地址，
并把那个整数的值存进 `f`。
而我们原本声明的是：

```c
  int   c;
  int   d;
  ...
  c= 12; d=18; printint(c);
  e= &c + 1; f= *e; printint(f);

```

因此最终就会把两个数都打印出来：

```
cc -o comp1 -g -Wall cg.c decl.c expr.c gen.c main.c misc.c
      scan.c stmt.c sym.c tree.c types.c
./comp1 tests/input16.c
cc -o out out.s lib/printint.c
./out
12
18
```

## 总结与下一步

我现在对这套“类型转换”代码比之前满意得多了。
在背后我还写了一些测试代码，
把所有可能的类型值都喂给 `modify_type()`，
并分别在“带二元运算”和“不带运算”的情况下观察输出。
我人工检查之后，
觉得目前结果基本符合预期。
但最终到底稳不稳，还得靠后面的实战来证明。

在编译器编写之旅的下一部分中，
说实话，我还没完全想好要先做什么！ [下一步](../18_Lvalues_Revisited/Readme.md)
