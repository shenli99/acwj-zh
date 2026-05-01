# 第 55 部分：惰性求值

我决定把修复 `&&` 和 `||`
这件事挪到这一部分来讲，
而不是放在前一部分，
因为前一章已经够长了。

那么，
为什么我们原先对 `&&` 和 `||` 的实现是有缺陷的？
C 程序员会期待这两个运算符遵循
[惰性求值（lazy evaluation）](https://en.wikipedia.org/wiki/Lazy_evaluation)。
换句话说，
只有当左侧操作数的值
还不足以决定最终结果时，
右侧操作数才会被求值。

惰性求值的一个常见用途是：
先判断某个指针是否指向特定值，
但前提是这个指针本身确实指向了某个有效位置。
`test/input138.c`
里就有一个例子：

```c
  int *aptr;
  ...
  if (aptr && *aptr == 1)
    printf("aptr points at 1\n");
  else
    printf("aptr is NULL or doesn't point at 1\n");
```

我们并不希望把 `&&`
两边的操作数都无脑求值。
如果 `aptr` 是 `NULL`，
那么 `*aptr == 1`
这个表达式就会触发一次对 `NULL` 的解引用，
程序也会直接崩掉。

## 问题出在哪里

问题在于，
我们当前对 `&&` 和 `||` 的实现
*确实会*
把两个操作数都求值。
在 `gen.c` 的 `genAST()` 中：

```c
  // Get the left and right sub-tree values
  leftreg = genAST(n->left, NOLABEL, NOLABEL, NOLABEL, n->op);
  rightreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);

  switch (n->op) {
    ...
    case A_LOGOR:
      return (cglogor(leftreg, rightreg));
    case A_LOGAND:
      return (cglogand(leftreg, rightreg));
    ...
  }
```

我们必须把这段逻辑重写成：
*不要* 总是同时求值两个操作数。
正确做法应该是：
先求左侧操作数。
如果光凭它就已经足以得到结果，
那就直接跳到设置结果值的代码。
如果还不够，
这时再去求右侧操作数。
然后同样根据右侧结果跳到设置结果的代码。
如果两边都没有触发跳转，
那最终结果自然就只能是相反值。

这套逻辑和 IF 语句的代码生成器很像，
但又没有像到可以直接复用。
所以我在 `gen.c` 里另外写了一个新的代码生成器。
它会在对左右操作数执行 `genAST()`
之前就先被调用。
代码大致分阶段如下：

```c
// Generate the code for an
// A_LOGAND or A_LOGOR operation
static int gen_logandor(struct ASTnode *n) {
  // Generate two labels
  int Lfalse = genlabel();
  int Lend = genlabel();
  int reg;

  // Generate the code for the left expression
  // followed by the jump to the false label
  reg= genAST(n->left, NOLABEL, NOLABEL, NOLABEL, 0);
  cgboolean(reg, n->op, Lfalse);
  genfreeregs(NOREG);
```

左侧操作数会先被求值。
假设我们当前处理的是 `&&` 运算。
如果这个结果为零，
那就可以直接跳到 `Lfalse`，
并把结果设为零
（也就是 false）。
另外，
表达式一旦求值完成，
我们就可以释放所有寄存器。
这也顺手减轻了寄存器分配时的压力。

```c
  // Generate the code for the right expression
  // followed by the jump to the false label
  reg= genAST(n->right, NOLABEL, NOLABEL, NOLABEL, 0);
  cgboolean(reg, n->op, Lfalse);
  genfreeregs(reg);
```

对于右侧操作数，
我们做完全一样的事。
如果它为假，
那就跳转到 `Lfalse` 标签。
如果没有跳转，
那么 `&&` 的结果就必然为真。
对于 `&&`，
后续代码现在会这样写：

```c
  cgloadboolean(reg, 1);
  cgjump(Lend);
  cglabel(Lfalse);
  cgloadboolean(reg, 0);
  cglabel(Lend);
  return(reg);
}
```

`cgloadboolean()`
会把寄存器设成 true
（参数为 1 时）
或者 false
（参数为 0 时）。
在 x86-64 上，
这两个值分别就是 1 和 0；
不过我还是把它写成这种形式，
以便未来如果换到别的架构上，
true 和 false 对应的寄存器值不同，
也还能正常工作。
上面这套逻辑会为表达式
`(aptr && *aptr == 1)`
生成如下输出：

```
        movq    aptr(%rip), %r10
        test    %r10, %r10              # Test if aptr is not NULL
        je      L38                     # No, jump to L38
        movq    aptr(%rip), %r10
        movslq  (%r10), %r10            # Get *aptr in %r10
        movq    $1, %r11
        cmpq    %r11, %r10              # Is *aptr == 1?
        sete    %r11b
        movzbq  %r11b, %r11
        test    %r11, %r11
        je      L38                     # No, jump to L38
        movq    $1, %r11                # Both true, true is the result
        jmp     L39                     # Skip the false code
L38:
        movq    $0, %r11                # One or both false, false is the result
L39:                                    # Continue on with the rest
```

我这里没有把 `||`
对应的 C 代码也一并贴出来。
本质上它的逻辑就是：
只要左边或右边任意一侧为真，
就跳转并把结果设成 true。
如果两边都没有触发这个跳转，
那就自然会落到设置 false 的代码里，
并且再跳过设置 true 的那部分代码。

## 测试这些修改

`test/input138.c`
里还写了代码来打印 AND 和 OR 的真值表：

```c
  // See if generic AND works
  for (x=0; x <= 1; x++)
    for (y=0; y <= 1; y++) {
      z= x && y;
      printf("%d %d | %d\n", x, y, z);
    }

  // See if generic AND works
  for (x=0; x <= 1; x++)
    for (y=0; y <= 1; y++) {
      z= x || y;
      printf("%d %d | %d\n", x, y, z);
    }
```

它会产生下面这些输出
（这里额外加了空行来方便阅读）：

```
0 0 | 0
0 1 | 0
1 0 | 0
1 1 | 1

0 0 | 0
0 1 | 1
1 0 | 1
1 1 | 1
```

## 总结与下一步

现在编译器已经正确支持 `&&` 和 `||`
的惰性求值了，
而这确实是编译器想要成功编译自己时
必须具备的能力。
事实上，
走到这一步，
编译器在处理它自己源码时
唯一还不会解析的东西，
就是局部数组（local arrays）的声明与使用。
所以，
接下来要做什么，
你应该已经能猜到了。

在编译器编写之旅的下一部分中，
我会试着搞清楚
局部数组该如何声明和使用。 [下一步](../56_Local_Arrays/Readme.md)
