# 第 0 部分：介绍

我决定踏上一段编译器编写之旅。过去我写过一些
[汇编器（assembler）](https://github.com/DoctorWkt/pdp7-unix/blob/master/tools/as7)，
也写过一个面向无类型语言的
[简单编译器](https://github.com/DoctorWkt/h-compiler)，
但我从来没有写过一个能够编译自身的编译器。
所以，这就是这段旅程的目标。

作为整个过程的一部分，我会把自己的工作记录下来，这样其他人也能一路跟着做。
这也能帮助我梳理自己的想法和设计思路。
希望你我都会觉得它有帮助。

## 这段旅程的目标

下面是这段旅程的目标，以及一些明确不打算做的事：

 + 写出一个可自举的编译器。我认为，如果一个编译器能够编译自己，
   那它才配得上“真正的编译器”这个称呼。
 + 至少支持一个真实硬件平台。我见过一些编译器只给假想机器生成代码。
   我希望自己的编译器能运行在真正的硬件上。并且如果可能的话，
   我也希望它的设计能够支持多个不同硬件平台的后端。
 + 实践优先于研究。编译器领域有大量研究成果，但我想从零开始，
   所以会优先采用实践导向的方法，而不是理论过重的方法。
   当然，过程中有些地方仍然需要引入并实现一些理论性的内容。
 + 遵循 KISS 原则：保持简单，别自作聪明。我肯定会采用 Ken Thompson 的原则：
   “如果拿不准，就用蛮力。”
 + 用很多小步骤抵达最终目标。我会把整段旅程拆成很多简单步骤，
   而不是一次跨很大的步子。这样每次给编译器增加的新能力都会变得小巧、
   容易理解和消化。

## 目标语言

选择目标语言并不容易。如果我选择 Python、Go 这类高级语言，
那就必须先实现一大堆语言内建的库和类。

我也可以为 Lisp 这样的语言写编译器，但这类工作
[已经可以很轻松地完成](ftp://publications.ai.mit.edu/ai-publications/pdf/AIM-039.pdf)。

所以，我最终还是选择了经典路线：为 C 语言的一个子集编写编译器，
功能只要足以让编译器编译自己就够了。

C 基本上只比汇编语言高一层
（至少这里指的是某个 C 子集，而不是
[C18](https://en.wikipedia.org/wiki/C18_(C_standard_revision))），
这能让我们把 C 代码编译成汇编的任务简单一些。
当然，我本来也喜欢 C。

## 编译器工作的基本内容

编译器的工作，是把一种语言中的输入
（通常是高级语言）翻译成另一种输出语言
（通常比输入语言更底层）。主要步骤如下：

![](Figs/parsing_steps.png)

 + 做[词法分析（lexical analysis）](https://en.wikipedia.org/wiki/Lexical_analysis)，
   识别词法元素。在很多语言里，`=` 和 `==` 的含义不同，
   所以你不能只读一个 `=` 就完事。我们把这些词法元素称为 *token*。
 + 对输入进行[语法解析（parse）](https://en.wikipedia.org/wiki/Parsing)，
   也就是识别输入中的语法与结构元素，并确保它们符合该语言的 *grammar*（语法）。
   例如，你的语言里可能会有这样的条件结构：

```
      if (x < 23) {
        print("x is smaller than 23\n");
      }
```

> 但在另一种语言中，你也许会写成：

```
      if (x < 23):
        print("x is smaller than 23\n")
```

> 这一步也是编译器发现语法错误的地方，例如第一条 *print* 语句结尾忘了加分号。

 + 做[语义分析（semantic analysis）](https://en.wikipedia.org/wiki/Semantic_analysis_(compilers))，
   也就是理解输入的含义。它和“识别语法结构”并不是一回事。
   例如在英语中，一个句子可能具有 `<subject> <verb> <adjective> <object>` 这样的结构。
   下面这两个句子结构相同，但含义完全不同：

```
          David ate lovely bananas.
          Jennifer hates green tomatoes.
```

 + 将输入的含义[翻译（translate）](https://en.wikipedia.org/wiki/Code_generation_(compiler))
   成另一种语言。这里我们会把输入分块转换成更底层的语言。
  
## 参考资料

互联网上有很多关于编译器的资料。下面是我会重点参考的一些内容。

### 学习资料

如果你想先看一些关于编译器的书、论文和工具，我非常推荐下面这份清单：

  + [Curated list of awesome resources on Compilers, Interpreters and Runtimes](https://github.com/aalhour/awesome-compilers)，作者 Ahmad Alhour

### 现有编译器

虽然我要自己构建一个编译器，但我计划参考其他编译器的思路，
并且很可能借用其中一些代码。下面是我正在参考的项目：

  + [SubC](http://www.t3x.org/subc/)，作者 Nils M Holm
  + [Swieros C Compiler](https://github.com/rswier/swieros/blob/master/root/bin/c.c)，作者 Robert Swierczek
  + [fbcc](https://github.com/DoctorWkt/fbcc)，作者 Fabrice Bellard
  + [tcc](https://bellard.org/tcc/)，同样来自 Fabrice Bellard 及其他贡献者
  + [catc](https://github.com/yui0/catc)，作者 Yuichiro Nakada
  + [amacc](https://github.com/jserv/amacc)，作者 Jim Huang
  + [Small C](https://en.wikipedia.org/wiki/Small-C)，作者 Ron Cain、James E. Hendrix，以及其他人的衍生版本

尤其是，我会大量借鉴 SubC 编译器中的思路，甚至复用其中一部分代码。

## 搭建开发环境

假设你想跟着一起走完这段旅程，那么你需要准备下面这些环境。
我会使用 Linux 作为开发环境，所以请下载并配置你喜欢的 Linux 系统：
我自己用的是 Lubuntu 18.04。

我计划面向两个硬件平台：Intel x86-64 和 32 位 ARM。
Intel 目标平台是一台运行 Lubuntu 18.04 的 PC，
ARM 目标平台是一台运行 Raspbian 的 Raspberry Pi。

在 Intel 平台上，我们需要一个现成的 C 编译器。
因此，请安装下面这个软件包（这里给出的是 Ubuntu/Debian 下的命令）：

```
  $ sudo apt-get install build-essential
```

如果一个标准 Linux 系统还需要别的工具，请告诉我。

最后，克隆一份这个 Github 仓库即可。

## 下一步

在这段编译器编写之旅的下一部分中，我们会先从扫描输入文件开始，
找出组成这门语言词法元素的 *token*。 [下一步](../01_Scanner/Readme.md)
