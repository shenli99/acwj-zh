# 第 59 部分：为什么它就是不工作（Why Doesn't It Work），第 1 部分

我们已经进入 **WDIW** 阶段了：
why doesn't it work?
在这个阶段的第一部分里，
我先找到并修掉了几个比较容易定位的 bug。
这也意味着，
后面肯定还藏着一些更隐蔽的问题，
等着我们慢慢挖出来。

## `*argv[i]` 的错误代码生成

我现在用 `cwj`
（也就是用 Gnu C 编译出来的版本）
去构建 `cwj0`。
`cwj0` 里的汇编代码
是 *我们自己* 生成出来的，
并不是 Gnu C 生成的。
所以，
当我们运行 `cwj0`
出现错误时，
那就说明是我们自己的汇编代码不正确。

我首先注意到的一个 bug 是：
`*argv[i]`
生成出来的代码，
看起来像是在按 `(*argv)[i]`
来处理，
也就是说它总是取 `*argv`
里的第 *i* 个字符，
而不是 `argv[i]`
所指向字符串的第一个字符。

我起初还以为这是解析错误，
但并不是。
真正的问题是：
我们在对 `argv[i]`
做解引用之前，
并没有先把它标记成 rvalue。
我是通过把 `cwj`
和 `cwj0`
生成的 AST 树都 dump 出来，
再对比差异，
才把这个问题定位出来的。
正确做法是：
把 `*` token
后面的那整个表达式标成 rvalue。
现在这件事是在 `expr.c`
的 `prefix()` 里完成的：

```c
static struct ASTnode *prefix(int ptp) {
  struct ASTnode *tree;
  switch (Token.token) {
  ...
  case T_STAR:
    // Get the next token and parse it
    // recursively as a prefix expression.
    // Make it an rvalue
    scan(&Token);
    tree = prefix(ptp);
    tree->rvalue= 1;
```

## `extern` 同样也是全局变量

这个问题以后肯定还会继续咬我。
我又找到一个地方，
自己没有把 `extern`
符号按“全局符号”来处理。
这次出问题的位置
是在 `gen.c`
的 `genAST()` 里，
也就是生成赋值汇编代码的地方。
修复如下：

```c
      // Now into the assignment code
      // Are we assigning to an identifier or through a pointer?
      switch (n->right->op) {
        case A_IDENT:
          if (n->right->sym->class == C_GLOBAL ||
              n->right->sym->class == C_EXTERN ||
              n->right->sym->class == C_STATIC)
            return (cgstorglob(leftreg, n->right->sym));
          else
            return (cgstorlocal(leftreg, n->right->sym));
```

## 扫描器是正常工作的

到了这个阶段，
`cwj0`
已经能够读取源码输入，
但完全没有产生任何输出。
为此我在 `Makefile`
里加了新的规则：

```
# Try to do the triple test
triple: cwj1

cwj1: cwj0 $(SRCS) $(HSRCS)
        ./cwj0 -o cwj1 $(SRCS)

cwj0: install $(SRCS) $(HSRCS)
        ./cwj -o cwj0 $(SRCS)
```

这样一来，
执行一次 `$ make triple`
就会先用 Gnu C 构建 `cwj`，
再用 `cwj` 构建 `cwj0`，
最后再用 `cwj0` 构建 `cwj1`。
后面我还会再回来说这件事。

但眼下的问题是：
`cwj1`
根本造不出来，
因为连汇编输出都没有！
所以问题变成了：
编译器到底执行到了哪里？
为了搞清楚这一点，
我在 `scan()`
函数的末尾加了一个 `printf()`：

```c
  // We found a token
  t->tokstr = Tstring[t->token];
  printf("Scanned %d\n", t->token);
  return (1);
```

加上这段之后，
我看到
`cwj` 和 `cwj0`
都会扫描出 50,404 个 token，
而且它们得到的 token 流完全一致。
因此我们可以得出结论：
至少到 `scan()`
这一层为止，
一切都还正常。

但是，
`./cwj0 -S -T cg.c`
的输出里却看不到任何 AST 树。
如果我运行 `gdb cwj0`，
在 `dumpAST()`
上打断点，
然后带着 `-S -T cg.c`
这些参数运行，
程序会在命中这个断点之前就退出。
它甚至都没有走到 `function_declaration()`。
那到底为什么会这样？

啊，
我发现了一次对 `0(%rbp)`
的内存访问。
这本来绝对不该发生，
因为所有局部变量
相对于帧指针都应该在负偏移位置。
继续检查 `cg.c`
里的 `cgaddress()`，
果然又是一个漏掉 `extern`
处理的地方。
现在代码是这样的：

```c
int cgaddress(struct symtable *sym) {
  int r = alloc_register();

  if (sym->class == C_GLOBAL ||
      sym->class == C_EXTERN ||
      sym->class == C_STATIC)
    fprintf(Outfile, "\tleaq\t%s(%%rip), %s\n", sym->name, reglist[r]);
  else
    fprintf(Outfile, "\tleaq\t%d(%%rbp), %s\n", sym->st_posn, reglist[r]);
  return (r);
}
```

这些 `extern`
相关问题真是要命。
不过这全是我自己的锅，
该背的责任还是得我来背。

## 错误的比较

加上上面的修复之后，
我们现在又会在下面这个地方失败：

```
$ ./cwj0 -S tests/input001.c 
invalid digit in integer literal:e on line 1 of tests/input001.c
```

最后查出来，
问题是 `scan.c`
里 `scanint()`
中的这个循环：

```c
static int scanint(int c) {
  int k;
  ...
  // Convert each character into an int value
  while ((k = chrpos("0123456789abcdef", tolower(c))) >= 0) {
```

这里发生的事情是：
`k=` 这次赋值，
不仅会把结果写回内存，
它本身还作为一个表达式来参与比较，
也就是这里的 `k >= 0`。
而 `k`
本身是 `int` 类型，
它被赋值回内存时，
用的是下面这样的存储：

```
    movl    %r10d, -8(%rbp)
```

当 `chrpos()`
返回 `-1` 时，
这个值会先被截断成 32 位
（也就是 `0xffffffff`），
再写入 `-8(%rbp)`，
也就是变量 `k` 所在的位置。
但在随后的比较中：

```
    movslq  -8(%rbp), %r10    # Load value back from k
    movq    $0, %r11          # Load zero
    cmpq    %r11, %r10        # Compare k's value against zero
```

我们又把 `k`
这个 *32 位* 值装进了 `%r10`，
接着做了一次 *64 位* 比较。
问题就来了：
作为 64 位值来看，
`0xffffffff`
居然会被当成正数。
于是循环条件仍然为真，
程序不会在该退出的时候退出。

正确做法应该是：
比较时要根据操作数的大小，
选择不同的 `cmp`
指令。
于是我把 `cg.c`
里的 `cgcompare_and_set()`
改成了这样：

```c
int cgcompare_and_set(int ASTop, int r1, int r2, int type) {
  int size = cgprimsize(type);
  ...
  switch (size) {
  case 1:
    fprintf(Outfile, "\tcmpb\t%s, %s\n", breglist[r2], breglist[r1]);
    break;
  case 4:
    fprintf(Outfile, "\tcmpl\t%s, %s\n", dreglist[r2], dreglist[r1]);
    break;
  default:
    fprintf(Outfile, "\tcmpq\t%s, %s\n", reglist[r2], reglist[r1]);
  }
  ...
}
```

现在，
比较时终于会使用正确大小的指令了。
另外还有一个类似的函数，
叫 `cgcompare_and_jump()`。
找个时间我应该把这两个函数重构合并一下。

# 现在，真的只差一点点了

我们已经非常接近
那个俗称 **triple test**
的里程碑了。
所谓 triple test，
就是先用一个现有编译器
把我们的编译器从源码编译出来
（stage 1）。
然后再用这个编译器去编译它自己
（stage 2）。
最后，
为了证明编译器已经真正具备自编译能力，
再用 stage 2 编译器继续编译它自己，
得到 stage 3 编译器。

现在我们已经可以：

 + 用 Gnu C 编译器构建 `cwj`（stage 1）
 + 用 `cwj` 编译器构建 `cwj0`（stage 2）
 + 用 `cwj0` 编译器构建 `cwj1`（stage 3）

但是，
`cwj0`
和 `cwj1`
的二进制大小并不一致：

```
$ size cwj[01]
   text    data     bss     dec     hex filename
 109636    3028      48  112712   1b848 cwj0
 109476    3028      48  112552   1b7a8 cwj1
```

而它们本来应该 *完全一致*。
只有当编译器能够连续多次编译自己，
并始终产出完全相同的结果时，
我们才真正能说：
它已经正确地具备了自编译能力。

在这两个结果还不能严格一致之前，
就说明 stage 2 和 stage 3
之间仍然存在某种细微的行为差异，
因此这个编译器还没有做到稳定一致地编译自己。

## 总结与下一步

老实说，
我原本并不觉得自己能这么快走到
可以连续构建 `cwj`、`cwj0` 和 `cwj1`
这一步。
我本来以为，
在抵达这里之前，
我们还会先撞上一大堆 bug。

接下来的问题是：
为什么 stage 2 和 stage 3
构建出来的编译器大小不同？
从 `size`
命令的输出看，
`data` 和 `bss`
段是一样的，
不同的是汇编代码量。

在编译器编写之旅的下一部分中，
我们会尝试对不同 stage
生成的汇编输出做并排比较，
找出这个差异到底是从哪里来的。

> 附带一提，在这一部分的过程中，
  我还开始尝试添加一些汇编输出，
  希望能让 `gdb`
  看到当前停在哪一行源码上。
  这件事暂时还没完全做通，
  但如果你去看代码，
  会发现 `cg.c`
  里已经多了一个新函数 `cglinenum()`。
  等我把它真正搞定后，
  我会再专门写一段说明。 [下一步](../60_TripleTest/Readme.md)
