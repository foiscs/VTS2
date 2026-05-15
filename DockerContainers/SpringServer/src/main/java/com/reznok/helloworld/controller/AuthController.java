package com.reznok.helloworld.controller;

import com.reznok.helloworld.domain.User;
import com.reznok.helloworld.repository.UserRepository;
import com.reznok.helloworld.security.SessionHelper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.util.Optional;

@Controller
public class AuthController {

    private final UserRepository userRepository;
    private final SessionHelper sessionHelper;

    @Autowired
    public AuthController(UserRepository userRepository, SessionHelper sessionHelper) {
        this.userRepository = userRepository;
        this.sessionHelper = sessionHelper;
    }

    @GetMapping("/login")
    public String loginForm(Model model, HttpServletRequest req) {
        sessionHelper.currentUser(req).ifPresent(u -> model.addAttribute("currentUser", u));
        return "login";
    }

    @PostMapping("/login")
    public String loginSubmit(@RequestParam String username,
                              @RequestParam String password,
                              HttpServletResponse resp,
                              Model model) {
        Optional<User> opt = userRepository.findByUsername(username);
        if (opt.isPresent() && opt.get().getPassword().equals(password)) {
            sessionHelper.login(resp, opt.get());
            return "redirect:/board";
        }
        model.addAttribute("error", "아이디 또는 비밀번호가 올바르지 않습니다.");
        model.addAttribute("username", username);
        return "login";
    }

    @GetMapping("/logout")
    public String logout(HttpServletResponse resp) {
        sessionHelper.logout(resp);
        return "redirect:/login";
    }

    @GetMapping("/signup")
    public String signupForm(Model model) {
        model.addAttribute("user", new User());
        return "signup";
    }

    @PostMapping("/signup")
    public String signupSubmit(@ModelAttribute User user,
                               HttpServletResponse resp,
                               Model model) {
        if (user.getUsername() == null || user.getUsername().isEmpty()
                || user.getPassword() == null || user.getPassword().isEmpty()) {
            model.addAttribute("error", "아이디와 비밀번호는 필수입니다.");
            model.addAttribute("user", user);
            return "signup";
        }
        if (userRepository.findByUsername(user.getUsername()).isPresent()) {
            model.addAttribute("error", "이미 존재하는 아이디입니다.");
            model.addAttribute("user", user);
            return "signup";
        }

        user.setId(null);
        if (user.getRole() == null) user.setRole("USER");
        userRepository.save(user);
        sessionHelper.login(resp, user);
        return "redirect:/board";
    }
}
