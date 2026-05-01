# 第 62 部分：代码清理

这个版本的编译器，
本质上和第 60 部分里的那个版本差不多。
我在这一部分主要是想：
修一修注释、
修一些 bug、
做一点代码清理，
顺手重命名一些函数和变量，
等等。

## 一些小型 bug 修复

为了支持接下来准备做的那些改动，
我需要让 struct
里可以再嵌套 struct。
也就是说，
像下面这样的写法应该能成立：

```c
   printf("%d\n", thing.member1.age_in_years);
```

这里 `thing`
本身是一个 struct，
而它里面的 `member1`
也同样是 struct 类型。
要完成这种访问，
我们就得先从 `thing`
的基地址算出 `member1`
的偏移量，
然后再基于那个偏移量，
继续算出 `age_in_years`
的偏移量。

但原先做这件事的代码，
默认 `'.'`
左边的对象一定是一个拥有符号表条目、
也就拥有固定内存地址的变量。
我们现在得把它修成：
即便 `'.'`
左边已经是一个“之前算好的偏移量”，
也能正常工作。

好在这个修复并不难。
解析器本身不需要改，
不过先来看看当前已有的逻辑。
在 `expr.c`
的 `member_access()` 中：

```c
  // Check that the left AST tree is a struct or union.
  // If so, change it from an A_IDENT to an A_ADDR so that
  // we get the base address, not the value at this address.
  if (!withpointer) {
    if (left->type == P_STRUCT || left->type == P_UNION)
      left->op = A_ADDR;
```

这里我们会把左侧 AST 树
标成 `A_ADDR`
（而不是 `A_IDENT`），
表示：
我们需要的是它的基地址，
而不是那个地址处的值。

接下来就得修代码生成部分。
当我们遇到一个 `A_ADDR`
AST 节点时，
要么它代表的是“某个变量的地址”
（比如 `thing.member1`
里的 `thing`），
要么它的子树本身就已经计算出了偏移量
（比如 `member1.age_in_years`
里那个 `member1`
的偏移）。
所以现在在 `gen.c`
的 `genAST()` 里，
我们这样处理：

```c
  case A_ADDR:
    // If we have a symbol, get its address. Otherwise,
    // the left register already has the address because
    // it's a member access
    if (n->sym != NULL)
      return (cgaddress(n->sym));
    else
      return (leftreg);
```

本来这样应该就够了，
但还有最后一个地方也得补。
负责计算类型对齐的代码，
此前只考虑了“struct 里嵌套标量类型”的情况，
还不会处理“struct 里再嵌 struct”。
于是我把 `cg.c`
里的 `cgalign()`
改成了下面这样：

```c
// Given a scalar type, an existing memory offset
// (which hasn't been allocated to anything yet)
// and a direction (1 is up, -1 is down), calculate
// and return a suitably aligned memory offset
// for this scalar type. This could be the original
// offset, or it could be above/below the original
int cgalign(int type, int offset, int direction) {
  int alignment;

  // We don't need to do this on x86-64, but let's
  // align chars on any offset and align ints/pointers
  // on a 4-byte alignment
  switch (type) {
  case P_CHAR:
    break;
  default:
    // Align whatever we have now on a 4-byte alignment.
    // I put the generic code here so it can be reused elsewhere.
    alignment = 4;
    offset = (offset + direction * (alignment - 1)) & ~(alignment - 1);
  }
  return (offset);
}
```

现在除了 `P_CHAR`
以外，
所有类型都会按 4 字节对齐，
包括 struct 和 union。

## 已知但尚未修复的 bug

现在这个 GitHub 仓库已经公开了，
也逐渐开始有人关注，
所以陆续有人提交了一些 bug
和行为缺陷的反馈。
相关 open/closed issue 列表在这里：
![https://github.com/DoctorWkt/acwj/issues](https://github.com/DoctorWkt/acwj/issues)。
如果你发现了 bug
或者某些行为不符合预期，
也欢迎继续提。
不过我没法保证
自己一定有时间把它们全修掉！

## 下一步

我最近在看一些关于寄存器分配的资料，
目前觉得，
下一步大概会给编译器加上
线性扫描（linear scan）式的寄存器分配机制。
但想做到这一步，
我首先需要在编译流程里
加入一个中间表示（intermediate representation）阶段。
接下来的几个阶段，
大体都会朝这个目标推进；
只是到目前为止，
我还没真正写出什么实质代码。 [下一步](../63_QBE/Readme.md)
