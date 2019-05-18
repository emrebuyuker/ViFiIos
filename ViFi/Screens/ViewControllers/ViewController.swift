//
//  ViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 6.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import SDWebImage

class ViewController: UIViewController, EFImageViewZoomDelegate {
    
    @IBOutlet weak var imageViewZoom: EFImageViewZoom!
    
    var imageURL = String()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.imageViewZoom._delegate = self
        self.imageViewZoom.imageView.sd_setImage(with: URL(string: imageURL, relativeTo: nil), placeholderImage: nil)
        self.imageViewZoom.contentMode = .left
        
    }
}

