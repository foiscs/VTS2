package com.reznok.helloworld.controller;

import com.reznok.helloworld.domain.Post;
import com.reznok.helloworld.domain.User;
import com.reznok.helloworld.repository.PostRepository;
import com.reznok.helloworld.security.SessionHelper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

@Controller
public class BoardController {

    private final PostRepository postRepository;
    private final SessionHelper sessionHelper;

    @Autowired
    public BoardController(PostRepository postRepository, SessionHelper sessionHelper) {
        this.postRepository = postRepository;
        this.sessionHelper = sessionHelper;
    }

    @GetMapping({"/", "/board"})
    public String list(Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        List<Post> posts = postRepository.findAll();
        model.addAttribute("posts", posts);
        model.addAttribute("currentUser", me.get());
        return "board";
    }

    @GetMapping("/post/{id}")
    public String view(@PathVariable Long id, Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        Optional<Post> opt = postRepository.findById(id);
        if (!opt.isPresent()) return "redirect:/board";

        Post p = opt.get();
        p.setViews(p.getViews() + 1);
        postRepository.save(p);

        model.addAttribute("post", p);
        model.addAttribute("currentUser", me.get());
        return "post";
    }

    /* ----- write (Spring4Shell sink) --------------------------------- */

    @GetMapping("/post/write")
    public String writeForm(Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";
        model.addAttribute("post", new Post());
        model.addAttribute("currentUser", me.get());
        return "write";
    }

    @PostMapping("/post/write")
    public String writeSubmit(@ModelAttribute Post post, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        post.setId(null);
        post.setAuthor(me.get().getUsername());
        post.setAuthorId(me.get().getId());
        post.setCreatedAt(LocalDateTime.now());
        post.setViews(0);
        if (post.getCategory() == null || post.getCategory().isEmpty()) {
            post.setCategory("자유");
        }
        Post saved = postRepository.save(post);
        return "redirect:/post/" + saved.getId();
    }

    /* ----- edit -------------------------------------------------------- */

    @GetMapping("/post/edit")
    public String editForm(@RequestParam Long id, Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        Optional<Post> opt = postRepository.findById(id);
        if (!opt.isPresent()) return "redirect:/board";

        Post p = opt.get();
        if (!p.getAuthor().equals(me.get().getUsername()) && !"ADMIN".equals(me.get().getRole())) {
            return "redirect:/board";
        }

        model.addAttribute("post", p);
        model.addAttribute("currentUser", me.get());
        return "edit";
    }

    @PostMapping("/post/edit")
    public String editSubmit(@ModelAttribute Post post, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        Optional<Post> existing = postRepository.findById(post.getId());
        if (!existing.isPresent()) return "redirect:/board";

        Post e = existing.get();
        if (!e.getAuthor().equals(me.get().getUsername()) && !"ADMIN".equals(me.get().getRole())) {
            return "redirect:/board";
        }

        e.setTitle(post.getTitle());
        e.setContent(post.getContent());
        e.setCategory(post.getCategory());
        postRepository.save(e);
        return "redirect:/post/" + e.getId();
    }

    @GetMapping("/post/delete")
    public String delete(@RequestParam Long id, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";

        Optional<Post> existing = postRepository.findById(id);
        if (!existing.isPresent()) return "redirect:/board";

        if (!existing.get().getAuthorId().equals(me.get().getId()) && !"ADMIN".equals(me.get().getRole())) {
            return "redirect:/board";
        }

        postRepository.deleteById(id);
        return "redirect:/board";
    }
}
