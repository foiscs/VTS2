package com.reznok.helloworld.controller;

import com.reznok.helloworld.domain.User;
import com.reznok.helloworld.repository.PostRepository;
import com.reznok.helloworld.repository.UserRepository;
import com.reznok.helloworld.security.SessionHelper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

import javax.servlet.http.HttpServletRequest;
import java.util.Optional;

@Controller
public class AdminController {

    private final UserRepository userRepository;
    private final PostRepository postRepository;
    private final SessionHelper sessionHelper;

    @Autowired
    public AdminController(UserRepository userRepository,
                           PostRepository postRepository,
                           SessionHelper sessionHelper) {
        this.userRepository = userRepository;
        this.postRepository = postRepository;
        this.sessionHelper = sessionHelper;
    }

    @GetMapping("/admin")
    public String dashboard(Model model, HttpServletRequest req) {
        Optional<User> me = sessionHelper.currentUser(req);
        if (!me.isPresent()) return "redirect:/login";
        if (!"ADMIN".equals(me.get().getRole())) return "redirect:/board";
        model.addAttribute("currentUser", me.get());
        model.addAttribute("users", userRepository.findAll());
        model.addAttribute("posts", postRepository.findAll());
        return "admin";
    }
}
