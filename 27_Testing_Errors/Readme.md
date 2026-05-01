# 第 27 部分：回归测试与一个意外惊喜

最近这几步里，
我们的编译器编写之旅已经迈出了几次不算小的步子，
所以我觉得这一部分可以稍微喘口气。
我们把节奏放慢一点，
顺便回头审视一下目前为止的进展。

在上一部分里，
我意识到我们还没有一个办法去确认：
语法错误和语义错误的检查，
到底是不是真的在按预期工作。
所以我刚刚把 `tests/` 目录里的脚本重写了一遍，
专门补上这件事。

我从 1980 年代末就开始用 Unix，
所以我的自动化工具偏好一直都是 shell 脚本和 Makefile；
如果需要更复杂一点的工具，
我通常会写 Python 或 Perl 脚本
（对，我就是这么老）。

那我们就快速来看一下 `tests/` 目录中的 `runtest` 脚本。
虽然我说自己用了 Unix 脚本很多很多年，
但我绝对算不上什么脚本大师。

## `runtest` 脚本

这个脚本的职责是：
拿到一组输入程序，
用我们的编译器去编译它们，
运行生成出来的可执行文件，
再把输出和“已知正确的输出”进行比较。
如果一致，
测试就算成功；
否则就是失败。

我现在把它扩展成了这样：
如果某个输入对应有一个“错误输出文件”，
那我们就运行编译器，
捕获它的错误输出。
只要这份错误输出和预期错误输出一致，
那么测试同样算成功，
因为这说明编译器正确识别了坏输入。

下面我们分几段来看这个 `runtest` 脚本。

```
# Build our compiler if needed
if [ ! -f ../comp1 ]
then (cd ..; make)
fi
```

这里我使用了 `( ... )` 语法，
也就是创建一个 *sub-shell*（子 shell）。
它可以切换自己的工作目录，
而不影响原本外层 shell 的当前位置；
因此我们可以先退回上一层目录并重新编译编译器。

```
# Try to use each input source file
for i in input*
# We can't do anything if there's no file to test against
do if [ ! -f "out.$i" -a ! -f "err.$i" ]
   then echo "Can't run test on $i, no output file!"
```

这里的 `[` 其实就是外部 Unix 工具 *test(1)*。
哦，如果你以前没见过这种写法，
那 *test(1)* 的意思是：
*test* 这个命令的手册页位于 man page 的第一节，
所以你可以执行：

```
$ man 1 test
```

来查看它的说明。
通常 `/usr/bin/[` 这个可执行文件
会链接到 `/usr/bin/test`，
所以在 shell 脚本里写 `[`，
本质上就和运行 `test` 命令是一样的。

那这一句
`[ ! -f "out.$i" -a ! -f "err.$i" ]`
可以读成：
检查是否既不存在 `"out.$i"`，
也不存在 `"err.$i"`。
如果两个文件都没有，
那我们就只能报错说明没法测试。

```
   # Output file: compile the source, run it and
   # capture the output, and compare it against
   # the known-good output
   else if [ -f "out.$i" ]
        then
          # Print the test name, compile it
          # with our compiler
          echo -n $i
          ../comp1 $i

          # Assemble the output, run it
          # and get the output in trial.$i
          cc -o out out.s ../lib/printint.c
          ./out > trial.$i

          # Compare this agains the correct output
          cmp -s "out.$i" "trial.$i"

          # If different, announce failure
          # and print out the difference
          if [ "$?" -eq "1" ]
          then echo ": failed"
            diff -c "out.$i" "trial.$i"
            echo

          # No failure, so announce success
          else echo ": OK"
          fi
```

这就是脚本的主体部分了。
我觉得注释基本已经把逻辑讲清楚了，
不过有些细节还是值得补一句。
`cmp -s` 会比较两个文本文件；
其中 `-s` 的意思是“不输出比较结果内容”，
只通过退出码告诉我们它的判断：

> 0 if inputs are the same, 1  if  different,  2  if
  trouble. (from the man page)

而 `if [ "$?" -eq "1" ]` 这一句的意思是：
如果“上一条命令的退出值”恰好等于 1。
也就是说，
如果编译器输出和“已知正确输出”不一致，
那我们就宣布测试失败，
并用 `diff` 工具把两个文件之间的差异打印出来。

```
   # Error file: compile the source and
   # capture the error messages. Compare
   # against the known-bad output. Same
   # mechanism as before
   else if [ -f "err.$i" ]
        then
          echo -n $i
          ../comp1 $i 2> "trial.$i"
          cmp -s "err.$i" "trial.$i"
          ...
```

这一段会在存在错误文件 `err.$i` 时执行。
这次，
我们使用 shell 的 `2>` 语法，
把编译器的标准错误输出重定向到 `trial.$i` 中，
再把它和正确的错误输出做比较。
后面的逻辑和前面是一样的。

## 我们现在在做什么：回归测试

之前我其实没怎么专门聊过测试，
但现在是时候补一下了。
我过去也教过软件开发，
所以如果整个过程里完全不提测试，
未免有点说不过去。

我们现在做的事叫做
[**回归测试（regression testing）**](https://en.wikipedia.org/wiki/Regression_testing)。
Wikipedia 给出的定义是：

> Regression testing is the action of re-running functional and non-functional tests
> to ensure that previously developed and tested software still performs after a change.

由于我们的编译器在每一步都会发生变化，
所以必须确保：
每一次新改动都不会把前面步骤中的功能
（以及错误检查能力）弄坏。
因此每当我引入新改动时，
我都会顺手增加一个或多个测试：
a) 证明新功能确实可用；
b) 在未来的改动里继续重复执行这些测试。
只要所有测试都还能通过，
我就能比较有把握地认为：
新代码没有把旧代码弄坏。

### 功能测试

`runtests` 脚本会去寻找以 `out` 为前缀的文件，
并据此执行功能测试（functional testing）。
目前我们有：

```
tests/out.input01.c  tests/out.input12.c   tests/out.input22.c
tests/out.input02.c  tests/out.input13.c   tests/out.input23.c
tests/out.input03.c  tests/out.input14.c   tests/out.input24.c
tests/out.input04.c  tests/out.input15.c   tests/out.input25.c
tests/out.input05.c  tests/out.input16.c   tests/out.input26.c
tests/out.input06.c  tests/out.input17.c   tests/out.input27.c
tests/out.input07.c  tests/out.input18a.c  tests/out.input28.c
tests/out.input08.c  tests/out.input18.c   tests/out.input29.c
tests/out.input09.c  tests/out.input19.c   tests/out.input30.c
tests/out.input10.c  tests/out.input20.c   tests/out.input53.c
tests/out.input11.c  tests/out.input21.c   tests/out.input54.c
```

这意味着，
目前一共有 33 个独立的功能测试。
不过我现在很清楚，
我们的编译器其实还相当脆弱。
这些测试基本都没有真正“压一压”编译器：
它们大多只是每个几行的小程序。
后面我们会逐步加入一些更恶心的压力测试，
好让编译器更结实、更有韧性。

### 非功能测试

`runtests` 脚本会去寻找以 `err` 为前缀的文件，
并据此做错误相关测试。
目前我们有：

```
tests/err.input31.c  tests/err.input39.c  tests/err.input47.c
tests/err.input32.c  tests/err.input40.c  tests/err.input48.c
tests/err.input33.c  tests/err.input41.c  tests/err.input49.c
tests/err.input34.c  tests/err.input42.c  tests/err.input50.c
tests/err.input35.c  tests/err.input43.c  tests/err.input51.c
tests/err.input36.c  tests/err.input44.c  tests/err.input52.c
tests/err.input37.c  tests/err.input45.c
tests/err.input38.c  tests/err.input46.c
```

我在这一部分里新建了这 22 个“编译器错误检查测试”。
方法很直接：
我去编译器代码里找所有 `fatal()` 调用，
然后尽量为每一个调用写一个小输入文件，
让它能触发对应错误。
你可以自己去读一读这些配套源文件，
看看能不能猜出每个文件分别触发了哪一种语法错误或语义错误。

## 其他形式的测试

这毕竟不是一门完整的软件开发方法学课程，
所以我不会在测试话题上再铺开太多。
不过我还是会放几个链接，
非常建议你顺手去看一看：

  + [单元测试（Unit testing）](https://en.wikipedia.org/wiki/Unit_testing)
  + [测试驱动开发（Test-driven development）](https://en.wikipedia.org/wiki/Test-driven_development)
  + [持续集成（Continuous integration）](https://en.wikipedia.org/wiki/Continuous_integration)
  + [版本控制（Version control）](https://en.wikipedia.org/wiki/Version_control)

我目前还没有对我们的编译器做单元测试。
主要原因是：
代码当前在 API 层面变化太快了，
函数接口还非常流动。
我现在并不是按那种传统瀑布式开发模型在推进，
所以如果强行做很多单元测试，
大概率只会让我不断花时间重写测试本身，
去追最新的函数 API。

某种意义上说，
我现在其实是在“危险驾驶”：
代码里肯定还藏着不少潜在 bug，
只是我们还没把它们挖出来。

不过更确定的一点是：
还有*更多更多*的 bug，
会表现成“编译器看起来像是接受了 C 语言”，
但实际上根本不是这么回事。
目前这个编译器还远远没有满足
[最小惊讶原则（principle of least astonishment）](https://en.wikipedia.org/wiki/Principle_of_least_astonishment)。
后面我们还得专门花些时间，
把一个“正常 C 程序员会理所当然期待出现”的功能慢慢补齐。

## 一个意外惊喜

最后，
以当前这个编译器状态来看，
我们还收获了一个挺有意思的功能性意外。
之前我故意留空了一段代码，
没有去检查“函数调用的实参数量和类型”
是否和函数原型匹配（位于 `expr.c`）：

```
  // XXX Check type of each argument against the function's prototype
```

我当时故意没做，
是不想在那个阶段一下子塞进太多新代码。

现在既然已经有了函数原型，
我就一直想终于把 `printf()` 支持起来，
这样我们就能摆脱自制的 `printint()` 和 `printchar()` 函数。
但眼下还做不到完全正确，
因为 `printf()` 是一个
[可变参数函数（variadic function）](https://en.wikipedia.org/wiki/Variadic_function)：
它可以接受数量可变的参数。
而我们当前的编译器
只允许声明“参数数量固定”的函数。

*不过*，
这里就出现了这个意外惊喜：
正因为我们目前**不会检查函数调用中的参数个数**，
所以只要给 `printf()` 写一个现成原型，
我们就可以向它传*任意数量*的参数。
因此目前下面这段代码（`tests/input53.c`）是能工作的：

```c
int printf(char *fmt);

int main()
{
  printf("Hello world, %d\n", 23);
  return(0);
}
```

这还挺不错的！

不过这里有个坑。
按照现在给出的 `printf()` 原型，
`cgcall()` 里的清理代码在函数返回时
不会去调整栈指针，
因为原型里看起来“参数不到六个”。
可实际上，
我们完全可能用十个参数去调用 `printf()`：
那就会有四个参数被压到栈上，
但 `cgcall()` 却不会在 `printf()` 返回后
把这四个参数从栈上清掉。

## 总结与下一步

这一部分里没有新增编译器代码，
但我们现在已经开始测试编译器的错误检查能力了，
同时也拥有了 54 个回归测试，
用来帮助我们在加入新功能时
尽量不把已有功能搞坏。
另外，
也正是因为当前这个“阴差阳错的缺口”，
我们现在已经能用 `printf()`，
以及其他那些参数个数固定的外部函数。

在编译器编写之旅的下一部分中，
我大概会尝试：

 + 增加对外部预处理器（external pre-processor）的支持
 + 允许编译器处理命令行中给出的多个文件
 + 给编译器加上 `-o`、`-c` 和 `-S` 选项，
   让它在使用体验上更像一个“正常”的 C 编译器 [下一步](../28_Runtime_Flags/Readme.md)
